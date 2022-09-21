// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SenseiStake} from "./SenseiStake.sol";

/// @title A Service contract for handling SenseiStake Validators
/// @author Senseinode
/// @notice A service contract is where the deposits of a client are managed and all validator related tasks are performed. The ERC721 contract is the entrypoint for a client deposit, from there it is separeted into 32ETH chunks and then sent to different service contracts.
/// @dev This contract is the implementation for the proxy factory clones that are made on ERC721 contract function (createContract) (an open zeppelin solution to create the same contract multiple times with gas optimization). The openzeppelin lib: https://docs.openzeppelin.com/contracts/4.x/api/proxy#Clone
contract SenseistakeServicesContract is Initializable {
    using Address for address payable;

    /// @notice The life cycle of a services contract.
    enum State {
        PreDeposit,
        PostDeposit,
        Withdrawn
    }

    /// @notice Used in conjuction with `COMMISSION_RATE_SCALE` for determining service fees
    /// @dev Is set up on the constructor and can be modified with provided setter aswell
    /// @return commissionRate the commission rate
    uint32 public commissionRate;

    /// @notice Scale for getting the commission rate (service fee)
    uint32 private constant COMMISSION_RATE_SCALE = 1_000_000;

    /// @notice Used for determining from when the user deposit can be withdrawn.
    /// @dev The call of endOperatorServices function is the first step to withdraw the deposit. It changes the state to Withdrawn
    /// @return exitDate the exit date
    uint64 public exitDate;

    /// @notice The tokenId used to create this contract using the proxy clone
    uint256 public tokenId;

    /// @notice The amount of eth the operator can claim
    /// @return state the operator claimable amount (in eth)
    uint256 public operatorClaimable;

    /// @notice The address for being able to deposit to the ethereum deposit contract
    /// @return depositContractAddress deposit contract address
    address public immutable depositContractAddress;

    /// @notice The address of Senseistakes ERC721 contract address
    /// @return tokenContractAddress the token contract address (erc721)
    address public immutable tokenContractAddress;

    /// @notice Fixed amount of the deposit
    uint256 private constant FULL_DEPOSIT_SIZE = 32 ether;

    /// @notice The state of the lifecyle of the service contract. This allows or forbids to make any action.
    /// @dev This uses the State enum
    /// @return state the state
    State public state;

    event Claim(address receiver, uint256 amount);
    event ExitDateUpdated(uint64 newExitDate);
    event ServiceEnd();
    event ValidatorDeposited(bytes pubkey);
    event Withdrawal(address indexed to, uint256 value);

    error CallerNotAllowed();
    error CannotEndZeroBalance();
    error NotAllowedAtCurrentTime();
    error NotAllowedInCurrentState();
    error NotEarlierThanOriginalDate();
    error NotOperator();
    error TransferNotEnabled();
    error ValidatorAlreadyCreated();
    error ValidatorIsActive();
    error ValidatorNotActive();

    /// @notice Only the operator access.
    modifier onlyOperator() {
        if (msg.sender != Ownable(tokenContractAddress).owner()) {
            revert NotOperator();
        }
        _;
    }

    /// @notice Initializes the contract
    /// @dev Sets the eth deposit contract address
    /// @param ethDepositContractAddress_ The eth deposit contract address for creating validator
    constructor(address ethDepositContractAddress_) {
        tokenContractAddress = msg.sender;
        depositContractAddress = ethDepositContractAddress_;
    }

    /// @notice This is the receive function called when a user performs a transfer to this contract address
    receive() external payable {
        if (state == State.PreDeposit) {
            revert TransferNotEnabled();
        }
    }

    /// @notice Initializes the contract
    /// @dev Sets the commission rate, the operator address, operator data commitment and the tokenId
    /// @param commissionRate_  The service commission rate
    /// @param tokenId_ The token id that is used
    /// @param exitDate_ The exit date
    function initialize(
        uint32 commissionRate_,
        uint256 tokenId_,
        uint64 exitDate_
    ) external payable initializer {
        commissionRate = commissionRate_;
        tokenId = tokenId_;
        exitDate = exitDate_;
    }

    /// @notice This creates the validator sending ethers to the deposit contract.
    /// @param validatorPubKey_ The validator public key
    /// @param depositSignature_ The deposit_data.json signature
    /// @param depositDataRoot_ The deposit_data.json data root
    function createValidator(
        bytes calldata validatorPubKey_,
        bytes calldata depositSignature_,
        bytes32 depositDataRoot_
    ) external {
        if (msg.sender != tokenContractAddress) {
            revert CallerNotAllowed();
        }
        if (state != State.PreDeposit) {
            revert ValidatorAlreadyCreated();
        }
        state = State.PostDeposit;
        IDepositContract(depositContractAddress).deposit{
            value: FULL_DEPOSIT_SIZE
        }(
            validatorPubKey_,
            abi.encodePacked(uint96(0x010000000000000000000000), address(this)),
            depositSignature_,
            depositDataRoot_
        );
        emit ValidatorDeposited(validatorPubKey_);
    }

    /// @notice Allows user to start the withdrawal process
    /// @dev After a withdrawal is made in the validator, the receiving address is set to this contract address, so there will be funds available in here. This function needs to be called for being able to withdraw current balance
    function endOperatorServices() external {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert CannotEndZeroBalance();
        }
        if (state != State.PostDeposit) {
            revert NotAllowedInCurrentState();
        }
        if (block.timestamp < exitDate) {
            revert NotAllowedAtCurrentTime();
        }
        if (
            (msg.sender != tokenContractAddress) &&
            (msg.sender !=
                SenseiStake(tokenContractAddress).ownerOf(tokenId)) &&
            (msg.sender != Ownable(tokenContractAddress).owner())
        ) {
            revert CallerNotAllowed();
        }
        state = State.Withdrawn;
        if (balance > 32 ether) {
            uint256 profit = balance - 32 ether;
            uint256 finalCommission = (profit * commissionRate) /
                COMMISSION_RATE_SCALE;
            operatorClaimable += finalCommission;
        }
        emit ServiceEnd();
    }

    /// @notice Transfers to operator the claimable amount of eth
    function operatorClaim() external onlyOperator {
        uint256 claimable = operatorClaimable;
        if (claimable > 0) {
            operatorClaimable = 0;
            payable(Ownable(tokenContractAddress).owner()).sendValue(claimable);
            emit Claim(Ownable(tokenContractAddress).owner(), claimable);
        }
    }

    /// @notice For updating the exitDate
    /// @dev The exit date must be after the current exit date and it's only possible in PostDeposit state
    /// @param exitDate_ The new exit date
    function updateExitDate(uint64 exitDate_) external onlyOperator {
        if (state != State.PostDeposit) {
            revert ValidatorNotActive();
        }
        if (exitDate_ < exitDate) {
            revert NotEarlierThanOriginalDate();
        }
        exitDate = exitDate_;
        emit ExitDateUpdated(exitDate_);
    }

    /// @notice Withdraw the deposit to a beneficiary
    /// @dev The beneficiary must have deposted before. Is not possible to withdraw in PostDeposit state. Can only be called from the ERC721 contract
    /// @param beneficiary_ Who will receive the deposit
    function withdrawTo(address beneficiary_) external {
        // callable only from senseistake erc721 contract
        if (msg.sender != tokenContractAddress) {
            revert CallerNotAllowed();
        }
        if (state == State.PostDeposit) {
            revert ValidatorIsActive();
        }
        payable(beneficiary_).sendValue(
            address(this).balance - operatorClaimable
        );
        emit Withdrawal(
            beneficiary_,
            address(this).balance - operatorClaimable
        );
    }

    /// @notice Get withdrawable amount of a user
    /// @return amount the depositor is allowed withdraw
    function getWithdrawableAmount() external view returns (uint256) {
        if (state == State.PostDeposit) {
            return 0;
        }
        return address(this).balance - operatorClaimable;
    }
}
