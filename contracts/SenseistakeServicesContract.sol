// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.4;

// import "./SenseistakeBase.sol";
import "./interfaces/deposit_contract.sol";
import "./interfaces/ISenseistakeServicesContract.sol";
import * as ERC721Contract  from "./SenseistakeERC721.sol";
import "./libraries/Address.sol";

import "hardhat/console.sol";

contract SenseistakeServicesContract is ISenseistakeServicesContract, Ownable {
    using Address for address payable;

    // uint256 private constant HOUR = 3600;
    // uint256 private constant DAY = 24 * HOUR;
    // uint256 private constant WEEK = 7 * DAY;
    // uint256 private constant YEAR = 365 * DAY;
    uint256 private constant YEAR = 360 * days;
    uint256 private constant MAX_SECONDS_IN_EXIT_QUEUE = 1 * YEAR;
    uint256 private constant COMMISSION_RATE_SCALE = 100;
    uint256 private constant FULL_DEPOSIT_SIZE = 32 ether;

    // Packed into a single slot
    address public operatorAddress;
    uint24 public commissionRate;
    uint64 public exitDate;
    State public state;

    bytes32 public operatorDataCommitment;

    mapping(address => mapping(address => uint256)) private allowances;
    mapping(address => mapping(address => uint256)) private allowedWithdrawals;
    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;
    uint256 public operatorClaimable;

    // for being able to deposit to the ethereum deposit contracts
    address public depositContractAddress;

    // for getting the token contact address and then calling mint/burn methods
    address public tokenContractAddress;

    modifier onlyOperator() {
        require(
            msg.sender == operatorAddress,
            "Caller is not the operator"
        );
        _;
    }

    modifier onlyDepositor() {
        require(
            deposits[msg.sender] == 32 ether,
            "Caller is not the depositor"
        );
        _;
    }

    modifier initializer() {
        require(
            state == State.NotInitialized,
            "Contract is already initialized"
        );
        state = State.PreDeposit;
        _;
    }

    error NotEnoughBalance();

    function initialize(
        uint24 _commissionRate,
        address _operatorAddress,
        bytes32 _operatorDataCommitment
    )
        external
        initializer
    {
        require(uint256(commissionRate) <= COMMISSION_RATE_SCALE, "Commission rate exceeds scale");

        commissionRate = _commissionRate;
        operatorAddress = _operatorAddress;
        operatorDataCommitment = _operatorDataCommitment;
    }

    receive() payable external {
        if (state == State.PreDeposit) {
            revert("Plain Ether transfer not allowed");
        }
    }

    function setEthDepositContractAddress(address ethDepositContractAddress) 
        external
        override
        onlyOperator
    {
        require(depositContractAddress == address(0), "Already set up ETH deposit contract address");
        depositContractAddress = ethDepositContractAddress;
    }

    function setTokenContractAddress(address _tokenContractAddress) 
        external
        override
        onlyOperator
    {
        require(tokenContractAddress == address(0), "Already set up token contract address");
        tokenContractAddress = _tokenContractAddress;
    }

    function updateExitDate(uint64 newExitDate)
        external
        override
        onlyOperator
    {
        require(
            _state == State.PostDeposit,
            "Validator is not active"
        );

        require(
            newExitDate < _exitDate,
            "Not earlier than the original value"
        );

        _exitDate = newExitDate;
    }

    function createValidator(
        bytes calldata validatorPubKey, // 48 bytes
        bytes calldata depositSignature, // 96 bytes
        bytes32 depositDataRoot,
        uint64 exitDate
    )
        external
        override
        onlyDepositor
    {

        require(_state == State.PreDeposit, "Validator has been created");
        _state = State.PostDeposit;

        require(validatorPubKey.length == 48, "Invalid validator public key");
        require(depositSignature.length == 96, "Invalid deposit signature");
        require(_operatorDataCommitment == keccak256(
            abi.encodePacked(
                address(this),
                validatorPubKey,
                depositSignature,
                depositDataRoot,
                exitDate
            )
        ), "Data doesn't match commitment");

        _exitDate = exitDate;

        IDepositContract(depositContractAddress).deposit{value: FULL_DEPOSIT_SIZE}(
            validatorPubKey,
            abi.encodePacked(uint96(0x010000000000000000000000), address(this)),
            depositSignature,
            depositDataRoot
        );

        ERC721Contract.SenseistakeERC721(tokenContractAddress).safeMint(msg.sender);

        emit ValidatorDeposited(validatorPubKey);
    }

    function deposit()
        external
        payable
        override
    {
        require(
            _state == State.PreDeposit,
            "Validator already created"
        );

        _handleDeposit(msg.sender);
    }

    function depositOnBehalfOf(address depositor)
        external
        payable
        override
    {
        require(
            _state == State.PreDeposit,
            "Validator already created"
        );
        _handleDeposit(depositor);
    }

    function endOperatorServices()
        external
        override
    {
        uint256 balance = address(this).balance;
        require(balance > 0, "Can't end with 0 balance");
        require(_state == State.PostDeposit, "Not allowed in the current state");
        require((msg.sender == operatorAddress && block.timestamp > _exitDate) ||
                (_deposits[msg.sender] > 0 && block.timestamp > _exitDate + MAX_SECONDS_IN_EXIT_QUEUE), "Not allowed at the current time");

        _state = State.Withdrawn;

        if (balance > 32 ether) {
            uint256 profit = balance - 32 ether;
            uint256 finalCommission = profit * _commissionRate / COMMISSION_RATE_SCALE;
            _operatorClaimable += finalCommission;
        }

        emit ServiceEnd();
    }

    function operatorClaim()
        external
        override
        onlyOperator
        returns (uint256)
    {
        uint256 claimable = _operatorClaimable;
        if (claimable > 0) {
            _operatorClaimable = 0;
            payable(operatorAddress).sendValue(claimable);

            emit Claim(operatorAddress, claimable);
        }

        return claimable;
    }

    string private constant WITHDRAWALS_NOT_ALLOWED =
        "Not allowed when validator is active";

    // TODO: before finishing delete this method. IS NOT SAFE does not work.
    // TODO: just for being able to retrieve locked funds for testing.
    // function withdrawAll()
    //     external
    //     override
    //     returns (uint256)
    // {
    //     require(_state != State.PostDeposit, WITHDRAWALS_NOT_ALLOWED);
    //     uint256 value = _executeWithdrawal(msg.sender, payable(msg.sender), _deposits[msg.sender]);
    //     // uint256 value = _executeWithdrawal(msg.sender, payable(msg.sender), address(this).balance);
    //     return value;
    // }

    function approve(
        address spender,
        uint256 amount
    )
        public
        override
        returns (bool)
    {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    )
        external
        override
        returns (bool)
    {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    )
        external
        override
        returns (bool)
    {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] - subtractedValue);
        return true;
    }

    function forceDecreaseAllowance(
        address spender,
        uint256 subtractedValue
    )
        external
        override
        returns (bool)
    {
        uint256 currentAllowance = _allowances[msg.sender][spender];
        _approve(msg.sender, spender, currentAllowance - _min(subtractedValue, currentAllowance));
        return true;
    }

    function approveWithdrawal(
        address spender,
        uint256 amount
    )
        external
        override
        returns (bool)
    {
        _approveWithdrawal(msg.sender, spender, amount);
        return true;
    }

    function increaseWithdrawalAllowance(
        address spender,
        uint256 addedValue
    )
        external
        override
        returns (bool)
    {
        _approveWithdrawal(msg.sender, spender, _allowedWithdrawals[msg.sender][spender] + addedValue);
        return true;
    }

    function increaseWithdrawalAllowanceFromFactory(
        address spender,
        uint256 addedValue
    )
        external
        override
        onlyLatestContract("SenseistakeServicesContractFactory", msg.sender)
        returns (bool)
    {
        _approveWithdrawal(spender, msg.sender, _allowedWithdrawals[spender][msg.sender] + addedValue);
        return true;
    }

    // function increaseWithdrawalAllowanceFromToken(
    //     address spender,
    //     uint256 addedValue
    // )
    //     external
    //     override
    //     onlyLatestContract("SenseistakeERC20Wrapper", msg.sender)
    //     returns (bool)
    // {
    //     _approveWithdrawal(spender, msg.sender, _allowedWithdrawals[spender][msg.sender] + addedValue);
    //     return true;
    // }

    // TODO: perhaps do the same with decreaseWithdrawalAllowanceFromFactory
    // TODO: perhaps do the same with decreaseWithdrawalAllowanceFromToken

    function decreaseWithdrawalAllowance(
        address spender,
        uint256 subtractedValue
    )
        external
        override
        returns (bool)
    {
        _approveWithdrawal(msg.sender, spender, _allowedWithdrawals[msg.sender][spender] - subtractedValue);
        return true;
    }

    function forceDecreaseWithdrawalAllowance(
        address spender,
        uint256 subtractedValue
    )
        external
        override
        returns (bool)
    {
        uint256 currentAllowance = _allowedWithdrawals[msg.sender][spender];
        _approveWithdrawal(msg.sender, spender, currentAllowance - _min(subtractedValue, currentAllowance));
        return true;
    }

    function withdrawAllOnBehalfOf(
        address payable beneficiary
    )
        external
        override
        onlyLatestContract("SenseistakeServicesContractFactory", msg.sender)
        returns (uint256)
    {
        require(_state != State.PostDeposit, WITHDRAWALS_NOT_ALLOWED);
        uint256 spenderAllowance = _allowedWithdrawals[beneficiary][msg.sender];
        uint256 allDeposit = _deposits[beneficiary];
        if(spenderAllowance < allDeposit){ revert NotEnoughBalance(); }
        // Please note that there is no need to require(_deposit <= spenderAllowance)
        // here because modern versions of Solidity insert underflow checks
        _allowedWithdrawals[beneficiary][msg.sender] = 0;
        emit WithdrawalApproval(beneficiary, msg.sender, 0);
        uint256 value = _executeWithdrawal(beneficiary, payable(beneficiary), allDeposit);
        return value; 
    }

    function transferDeposit(
        address to,
        uint256 amount
    )
        external
        override
        returns (bool)
    {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferDepositFrom(
        address from,
        address to,
        uint256 amount
    )
        external
        override
        onlyLatestContract("SenseistakeServicesContractFactory", msg.sender)
        returns (bool)
    {
        _transfer(from, to, amount);
        return true;
    }

    function withdrawalAllowance(
        address depositor,
        address spender
    )
        external
        view
        override
        returns (uint256)
    {
        return _allowedWithdrawals[depositor][spender];
    }

    function getCommissionRate()
        external
        view
        override
        returns (uint256)
    {
        return _commissionRate;
    }

    function getExitDate()
        external
        view
        override
        returns (uint256)
    {
        return _exitDate;
    }

    function getState()
        external
        view
        override
        returns(State)
    {
        return _state;
    }

    function getDeposit(address depositor)
        external
        view
        override
        returns (uint256)
    {
        return _deposits[depositor];
    }

    function getTotalDeposits()
        external
        view
        override
        returns (uint256)
    {
        return _totalDeposits;
    }

    function getAllowance(
        address owner,
        address spender
    )
        external
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    function getOperatorDataCommitment()
        external
        view
        override
        returns (bytes32)
    {
        return _operatorDataCommitment;
    }

    function getOperatorClaimable()
        external
        view
        override
        returns (uint256)
    {
        return _operatorClaimable;
    }

    function getWithdrawableAmount(address owner)
        external
        view
        override
        returns (uint256)
    {
        if (_state == State.PostDeposit) {
            return 0;
        }

        return _deposits[owner] * (address(this).balance - _operatorClaimable) / _totalDeposits;
    }

    function _executeWithdrawal(
        address depositor,
        address payable beneficiary, 
        uint256 amount
    ) 
        internal
        returns (uint256)
    {
        require(amount > 0, "Amount shouldn't be zero");

        // Modern versions of Solidity automatically add underflow checks,
        // so we don't need to `require(_deposits[_depositor] < _deposit` here:
        _deposits[depositor] = 0;
        _totalDeposits = 0;

        emit Withdrawal(depositor, beneficiary, amount);
        beneficiary.sendValue(amount);

        if (_state == State.Withdrawn) {
            ERC721Contract.SenseistakeERC721(tokenContractAddress).burn();
        }

        return amount;
    }

    error DepositedAmountLowerThanFullDeposit();

    function _handleDeposit(address depositor)
        internal
    {
        if (msg.value < FULL_DEPOSIT_SIZE) { revert DepositedAmountLowerThanFullDeposit(); }
        
        uint256 surplus = (address(this).balance > 32 ether) ?
            (address(this).balance - 32 ether) : 0;

        uint256 acceptedDeposit = msg.value - surplus;

        _deposits[depositor] += acceptedDeposit;
        _totalDeposits += acceptedDeposit;
        
        emit Deposit(depositor, acceptedDeposit);
        
        if (surplus > 0) {
            payable(depositor).sendValue(surplus);
        }
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    )
        internal
    {
        require(to != address(0), "Transfer to the zero address");

        _deposits[from] -= amount;
        _deposits[to] += amount;

        emit Transfer(from, to, amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    )
        internal
    {
        require(spender != address(0), "Approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _approveWithdrawal(
        address owner,
        address spender,
        uint256 amount
    )
        internal
    {
        require(spender != address(0), "Approve to the zero address");

        _allowedWithdrawals[owner][spender] = amount;
        emit WithdrawalApproval(owner, spender, amount);
    }

    function _min(
        uint256 a,
        uint256 b
    )
        internal
        pure
        returns (uint256)
    {
        return a < b ? a : b;
    }
}
