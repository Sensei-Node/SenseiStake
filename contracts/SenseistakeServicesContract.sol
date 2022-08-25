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

import "./SenseistakeBase.sol";
import "./interfaces/deposit_contract.sol";
import "./interfaces/ISenseistakeServicesContract.sol";
import * as ERC721Contract  from "./SenseistakeERC721.sol";
import "./libraries/Address.sol";

import "hardhat/console.sol";

contract SenseistakeServicesContract is SenseistakeBase, ISenseistakeServicesContract {
    using Address for address payable;

    uint256 private constant HOUR = 3600;
    uint256 private constant DAY = 24 * HOUR;
    uint256 private constant WEEK = 7 * DAY;
    uint256 private constant YEAR = 365 * DAY;
    uint256 private constant MAX_SECONDS_IN_EXIT_QUEUE = 1 * YEAR;
    uint256 private constant COMMISSION_RATE_SCALE = 1000000;
    uint256 private constant DEPOSIT_AMOUNT_FOR_CREATE_VALIDATOR = 32 ether;

    // Packed into a single slot
    uint24 private _commissionRate;
    address private _operatorAddress;
    uint64 private _exitDate;
    State private _state;

    bytes32 private _operatorDataCommitment;

    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => mapping(address => uint256)) private _allowedWithdrawals;
    mapping(address => uint256) private _deposits;
    uint256 private _totalDeposits;
    uint256 private _operatorClaimable;

    IDepositContract public depositContract;

    // for getting the token contact address and then calling the mintTo method
    //ISenseistakeERC20Wrapper public tokenContractAddress;
    ERC721Contract.SenseistakeERC721 public tokenContractAddress;

    uint256 private _tokenId;
    string private _tokenURI;


    modifier onlyOperator() {
        require(
            msg.sender == _operatorAddress,
            "Caller is not the operator"
        );
        _;
    }

    modifier initializer() {
        require(
            _state == State.NotInitialized,
            "Contract is already initialized"
        );
        _state = State.PreDeposit;
        _;
    }

    error NotEnoughBalance();

    function initialize(
        uint24 commissionRate,
        address operatorAddress,
        bytes32 operatorDataCommitment,
        address senseistakeStorageAddress
    )
        external
        initializer
    {
        require(uint256(commissionRate) <= COMMISSION_RATE_SCALE, "Commission rate exceeds scale");

        _commissionRate = commissionRate;
        _operatorAddress = operatorAddress;
        _operatorDataCommitment = operatorDataCommitment;
        initializeSenseistakeStorage(senseistakeStorageAddress);
    }

    receive() payable external {
        if (_state == State.PreDeposit) {
            revert("Plain Ether transfer not allowed");
        }
    }

    //TODO agregar que solo el factory pueda acceder
    function setTokenId(uint256 tokenId) 
        external
        override
    {
        require(_tokenId == 0, "Already set up tokenId");
        _tokenId = tokenId;
    }


    //TODO agregar que solo el factory pueda acceder
    function setTokenURI(string memory tokenURL) 
        external
        override
    {
        //TODO esto debe estar descomentado
        //require(_tokenURL == 0, "Already set up tokenUrl");
        _tokenURI = tokenURL;
    }
    function setEthDepositContractAddress(address ethDepositContractAddress) 
        external
        override
        onlyOperator
    {
        require(address(depositContract) == address(0), "Already set up ETH deposit contract address");
        depositContract = IDepositContract(ethDepositContractAddress);
    }

    function setTokenContractAddress(address _tokenContractAddress) 
        external
        override
        onlyOperator
    {
        require(address(tokenContractAddress) == address(0), "Already set up erc20 contract address");
        tokenContractAddress = ERC721Contract.SenseistakeERC721(_tokenContractAddress);
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
        onlyOperator
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

        depositContract.deposit{value: DEPOSIT_AMOUNT_FOR_CREATE_VALIDATOR}(
            validatorPubKey,
            abi.encodePacked(uint96(0x010000000000000000000000), address(this)),
            depositSignature,
            depositDataRoot
        );

        emit ValidatorDeposited(validatorPubKey);
    }

    function deposit()
        external
        payable
        override
        returns (uint256 surplus)
    {
        require(
            _state == State.PreDeposit,
            "Validator already created"
        );

        return _handleDeposit(msg.sender);
    }

    function depositOnBehalfOf(address depositor)
        external
        payable
        override
        returns (uint256 surplus)
    {
        require(
            _state == State.PreDeposit,
            "Validator already created"
        );
        return _handleDeposit(depositor);
    }

    function endOperatorServices()
        external
        override
    {
        uint256 balance = address(this).balance;
        require(balance > 0, "Can't end with 0 balance");
        require(_state == State.PostDeposit, "Not allowed in the current state");
        require((msg.sender == _operatorAddress && block.timestamp > _exitDate) ||
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
            payable(_operatorAddress).sendValue(claimable);

            emit Claim(_operatorAddress, claimable);
        }

        return claimable;
    }

    string private constant WITHDRAWALS_NOT_ALLOWED =
        "Not allowed when validator is active";

    //function withdrawAll(/*uint256 minimumETHAmount*/)
    function withdrawAll()
        external
        override
        returns (uint256)
    {
        require(_state != State.PostDeposit, WITHDRAWALS_NOT_ALLOWED);
        // TODO: cambiar _deposits[msg.sender] por tokenId (ERC721)
        uint256 value = _executeWithdrawal(msg.sender, payable(msg.sender), address(this).balance);
        // require(value >= minimumETHAmount, "Less than minimum amount");
        return value;
    }

    /*function withdraw(
        uint256 amount
        // uint256 minimumETHAmount
    )
        external
        override
        returns (uint256)
    {
        require(_state != State.PostDeposit, WITHDRAWALS_NOT_ALLOWED);
        // TODO: cambiar amount por tokenId (ERC721)
        uint256 value = _executeWithdrawal(msg.sender, payable(msg.sender), amount);
        // require(value >= minimumETHAmount, "Less than minimum amount");
        return value;
    }*/

    /*function withdrawTo(
        uint256 amount,
        address payable beneficiary
        // uint256 minimumETHAmount
    )
        external
        override
        returns (uint256)
    {
        require(_state != State.PostDeposit, WITHDRAWALS_NOT_ALLOWED);
        // TODO: cambiar amount por tokenId (ERC721)
        uint256 value = _executeWithdrawal(msg.sender, beneficiary, amount);
        // require(value >= minimumETHAmount, "Less than minimum amount");
        return value;
    }*/

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
        //address beneficiary,
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

    function increaseWithdrawalAllowanceFromToken(
        address spender,
        uint256 addedValue
    )
        external
        override
        onlyLatestContract("SenseistakeERC20Wrapper", msg.sender)
        returns (bool)
    {
        _approveWithdrawal(spender, msg.sender, _allowedWithdrawals[spender][msg.sender] + addedValue);
        return true;
    }

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

    /*function withdrawFrom(
        address depositor,
        address payable beneficiary,
        uint256 amount
        // uint256 minimumETHAmount
    )
        external
        override
        returns (uint256)
    {
        require(_state != State.PostDeposit, WITHDRAWALS_NOT_ALLOWED);
        uint256 spenderAllowance = _allowedWithdrawals[depositor][msg.sender];
        uint256 newAllowance = spenderAllowance - amount;
        // Please note that there is no need to require(_deposit <= spenderAllowance)
        // here because modern versions of Solidity insert underflow checks
        _allowedWithdrawals[depositor][msg.sender] = newAllowance;
        emit WithdrawalApproval(depositor, msg.sender, newAllowance);
        // TODO: cambiar amount por tokenId (ERC721)
        uint256 value = _executeWithdrawal(depositor, beneficiary, amount);
        // require(value >= minimumETHAmount, "Less than minimum amount");
        return value; 
    }*/

    // function withdrawOnBehalfOf(
    //     //address depositor,
    //     address payable beneficiary,
    //     uint256 amount
    //     // uint256 minimumETHAmount
    // )
    //     external
    //     override
    //     onlyLatestContract("SenseistakeServicesContractFactory", msg.sender)
    //     returns (uint256)
    // {
    //     require(_state != State.PostDeposit, WITHDRAWALS_NOT_ALLOWED);
    //     uint256 spenderAllowance = _allowedWithdrawals[beneficiary][msg.sender];
    //     if(spenderAllowance < amount){ revert NotEnoughBalance(); }
    //     uint256 newAllowance = spenderAllowance - amount;
    //     // Please note that there is no need to require(_deposit <= spenderAllowance)
    //     // here because modern versions of Solidity insert underflow checks
    //     _allowedWithdrawals[beneficiary][msg.sender] = newAllowance;
    //     emit WithdrawalApproval(beneficiary, msg.sender, newAllowance);

    //     uint256 value = _executeWithdrawal(beneficiary, beneficiary, amount);
    //     // require(value >= minimumETHAmount, "Less than minimum amount");
    //     return value; 
    // }

    function withdrawAllOnBehalfOf(
        //address depositor,
        address payable beneficiary
        // uint256 minimumETHAmount
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
        // TODO: cambiar allDeposit por tokenId (ERC721)
        uint256 value = _executeWithdrawal(beneficiary, beneficiary, allDeposit);
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
        returns (bool)
    {
        uint256 spenderAllowance = _allowedWithdrawals[from][msg.sender];
        if(spenderAllowance < amount){ revert NotEnoughBalance(); }
        uint256 newAllowance = spenderAllowance - amount;
        // Please note that there is no need to require(_deposit <= spenderAllowance)
        // here because modern versions of Solidity insert underflow checks
        _allowedWithdrawals[from][msg.sender] = newAllowance;
        emit WithdrawalApproval(from, msg.sender, newAllowance);

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

    function getOperatorAddress()
        external
        view
        override
        returns (address)
    {
        return _operatorAddress;
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
        require(amount  == 32 ether, "Amount should be 32");

        //uint256 value =  (address(this).balance - _operatorClaimable) / _totalDeposits;
        uint256 value =  (amount - _operatorClaimable) / _totalDeposits;
        console.log("tokenId", _tokenId);
        tokenContractAddress.burn(_tokenId);

        // Modern versions of Solidity automatically add underflow checks,
        // so we don't need to `require(_deposits[_depositor] < _deposit` here:
        _deposits[depositor] = 0;
        _totalDeposits = 0;

        emit Withdrawal(depositor, beneficiary, value);
        beneficiary.sendValue(value);

        return value;
    }

    // NOTE: This throws (on underflow) if the contract's balance was more than
    // 32 ether before the call
    function _handleDeposit(address depositor)
        internal
        returns (uint256 surplus)
    {
        uint256 depositSize = msg.value;
        surplus = (address(this).balance > 32 ether) ?
            (address(this).balance - 32 ether) : 0;

        uint256 acceptedDeposit = depositSize - surplus;

        _deposits[depositor] += acceptedDeposit;
        _totalDeposits += acceptedDeposit;
        console.log("_handleDeposit tokenId", _tokenId);
        
        tokenContractAddress.safeMint(depositor, _tokenId);
        tokenContractAddress.setTokenURI(_tokenId, _tokenURI);
        
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
