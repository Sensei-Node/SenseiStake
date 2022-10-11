// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

    /// @notice Struct used for single atomic transaction 
    struct Operation {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Struct used for transactions (single or batch) that could be needed, only created by protocol owner and executed by token owner/allowed
    struct Transaction {
        Operation[] operations;
        uint8 executed;
        uint8 confirmed;
        uint8 valid;
        uint16 prev;
        uint16 next;
        string description;
    }

    /// @notice Used in conjuction with `COMMISSION_RATE_SCALE` for determining service fees
    /// @dev Is set up on the constructor and can be modified with provided setter aswell
    /// @return commissionRate the commission rate
    uint32 public commissionRate;

    /// @notice Used for determining from when the user deposit can be withdrawn.
    /// @return exitDate the exit date
    uint64 public exitDate;

    /// @notice The tokenId used to create this contract using the proxy clone
    /// @return tokenId of the NFT related to the service contract
    uint256 public tokenId;

    /// @notice The amount of eth the operator can claim
    /// @return state the operator claimable amount (in eth)
    uint256 public operatorClaimable;

    /// @notice List of transactions that might be proposed
    Transaction[] public transactions;

    /// @notice Determines whether the validator is active or not
    /// @return validatorActive is true if user holds NFT and validator is active, false if validator inactive and endOperatorServices called
    bool public validatorActive;

    /// @notice The address for being able to deposit to the ethereum deposit contract
    /// @return depositContractAddress deposit contract address
    address public immutable depositContractAddress;

    /// @notice The address of Senseistakes ERC721 contract address
    /// @return tokenContractAddress the token contract address (erc721)
    address public immutable tokenContractAddress;

    /// @notice Scale for getting the commission rate (service fee)
    uint32 private constant COMMISSION_RATE_SCALE = 1_000_000;

    /// @notice Prefix of eth1 address for withdrawal credentials
    uint96 private constant ETH1_ADDRESS_WITHDRAWAL_PREFIX =
        uint96(0x010000000000000000000000);

    /// @notice Fixed amount of the deposit
    uint256 private constant FULL_DEPOSIT_SIZE = 32 ether;

    event Claim(address indexed receiver, uint256 amount);
    event ExecuteTransaction(uint256 indexed index);
    event ExitDateUpdated(uint64 newExitDate);
    event ServiceEnd();
    event SubmitTransaction(
        uint256 indexed index,
        string indexed description
    );
    event CancelTransaction(
        uint256 indexed index
    );
    event ConfirmTransaction(
        uint256 indexed index
    );
    event ValidatorDeposited(bytes pubkey);
    event Withdrawal(address indexed to, uint256 value);

    error CallerNotAllowed();
    error CannotEndZeroBalance();
    error EmptyClaimableForOperator();
    error IncrementTooHigh();
    error NotAllowedAtCurrentTime();
    error NotAllowedInCurrentState();
    error NotEarlierThanOriginalDate();
    error NotOperator();
    error PreviousValidTransactionNotExecuted(uint16 index);
    error TransactionAlreadyExecuted();
    error TransactionAlreadyConfirmed();
    error TransactionIndexInvalid();
    error TransactionCallFailed();
    error TransactionNotValid();
    error TransactionNotConfirmed();
    error ValidatorIsActive();
    error ValidatorNotActive();

    /// @notice Only the operator access.
    modifier onlyOperator() {
        if (msg.sender != Ownable(tokenContractAddress).owner()) {
            revert NotOperator();
        }
        _;
    }

    /// @notice For determining if specified index for transactions list is valid
    /// @param index_: Transaction index to verify
    modifier txExists(uint256 index_) {
        if (index_ >= transactions.length) {
            revert TransactionIndexInvalid();
        }
        _;
    }

    /// @notice For determining if specified transaction index was not executed
    /// @param index_: Transaction index to verify
    modifier txNotExecuted(uint256 index_) {
        if (transactions[index_].executed == 1) {
            revert TransactionAlreadyExecuted();
        }
        _;
    }

    /// @notice For determining if specified transaction index was not confirmed by owner/allowed user
    /// @param index_: Transaction index to verify
    modifier txNotConfirmed(uint256 index_) {
        if (transactions[index_].confirmed == 1) {
            revert TransactionAlreadyConfirmed();
        }
        _;
    }

    /// @notice For determining if specified transaction index is valid (not canceled by protocol owner)
    /// @param index_: Transaction index to verify
    modifier txValid(uint256 index_) {
        if (transactions[index_].valid == 0) {
            revert TransactionNotValid();
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
    receive() external payable {}

    /// @notice Initializes the contract and creates validator
    /// @dev Sets the commission rate, the operator address, operator data commitment, the tokenId and creates the validator
    /// @param commissionRate_  The service commission rate
    /// @param tokenId_ The token id that is used
    /// @param exitDate_ The exit date
    /// @param validatorPubKey_ The validator public key
    /// @param depositSignature_ The deposit_data.json signature
    /// @param depositDataRoot_ The deposit_data.json data root
    function initialize(
        uint32 commissionRate_,
        uint256 tokenId_,
        uint64 exitDate_,
        bytes calldata validatorPubKey_,
        bytes calldata depositSignature_,
        bytes32 depositDataRoot_
    ) external payable initializer {
        commissionRate = commissionRate_;
        tokenId = tokenId_;
        exitDate = exitDate_;
        IDepositContract(depositContractAddress).deposit{
            value: FULL_DEPOSIT_SIZE
        }(
            validatorPubKey_,
            abi.encodePacked(ETH1_ADDRESS_WITHDRAWAL_PREFIX, address(this)),
            depositSignature_,
            depositDataRoot_
        );
        validatorActive = true;
        emit ValidatorDeposited(validatorPubKey_);
    }

    /// @notice For canceling a submited transaction if needed
    /// @dev Only protocol owner can do so
    /// @param index_: transaction index
    function cancelTransaction(uint256 index_)
        external
        txExists(index_)
        txValid(index_)
        txNotExecuted(index_)
        onlyOperator
    {
        if (transactions[index_].prev == transactions[index_].next) {
            // if it is the only element in the list
            delete transactions[index_];
            transactions.pop();
        } else {
            // if it is not the only element in the list
            if (transactions[index_].prev == type(uint16).max) {
                // if it is the first
                Transaction storage transactionNext = transactions[transactions[index_].next];
                transactionNext.prev = type(uint16).max;
            } else if (transactions[index_].next == type(uint16).max) {
                // if it is the last
                Transaction storage transactionPrev = transactions[transactions[index_].prev];
                transactionPrev.next = type(uint16).max;
            } else {
                // if it is in the middle
                Transaction storage transactionPrev = transactions[transactions[index_].prev];
                Transaction storage transactionNext = transactions[transactions[index_].next];
                transactionPrev.next = transactions[index_].next;
                transactionNext.prev = transactions[index_].prev;
            }
            delete transactions[index_];
        }
        emit CancelTransaction(index_);
    }

    /// @notice Token owner or allowed confirmation to execute transaction by protocol owner
    /// @param index_: transaction index to confirm
    function confirmTransaction(uint256 index_)
        external
        txExists(index_)
        txValid(index_)
        txNotConfirmed(index_)
        txNotExecuted(index_)
    {
        if (
            !SenseiStake(tokenContractAddress).isApprovedOrOwner(
                msg.sender,
                tokenId
            )
        ) {
            revert CallerNotAllowed();
        }
        Transaction storage transaction = transactions[index_];
        transaction.confirmed = 1;
        emit ConfirmTransaction(index_);
    }

    /// @notice Allows user to start the withdrawal process
    /// @dev After a withdrawal is made in the validator, the receiving address is set to this contract address, so there will be funds available in here. This function needs to be called for being able to withdraw current balance
    function endOperatorServices() external {
        uint256 balance = address(this).balance;
        if (balance < 16 ether) {
            revert CannotEndZeroBalance();
        }
        if (!validatorActive) {
            revert NotAllowedInCurrentState();
        }
        if (block.timestamp < exitDate) {
            revert NotAllowedAtCurrentTime();
        }
        if (
            (msg.sender != tokenContractAddress) &&
            (
                !SenseiStake(tokenContractAddress).isApprovedOrOwner(
                    msg.sender,
                    tokenId
                )
            ) &&
            (msg.sender != Ownable(tokenContractAddress).owner())
        ) {
            revert CallerNotAllowed();
        }
        validatorActive = false;
        if (balance > FULL_DEPOSIT_SIZE) {
            unchecked {
                uint256 profit = balance - FULL_DEPOSIT_SIZE;
                uint256 finalCommission = (profit * commissionRate) /
                    COMMISSION_RATE_SCALE;
                operatorClaimable += finalCommission;
            }
        }
        emit ServiceEnd();
    }

    /// @notice Executes transaction index_ that is valid, confirmed and not executed
    /// @dev Requires previous transaction valid to be executed
    /// @param index_: transaction at index to be executed
    function executeTransaction(uint256 index_)
        external
        onlyOperator
        txExists(index_)
        txValid(index_)
        txNotExecuted(index_)
    {
        Transaction storage transaction = transactions[index_];
        
        if (transaction.confirmed == 0) {
            revert TransactionNotConfirmed();
        }
        if (transaction.prev != type(uint16).max) {
            if (transactions[transaction.prev].executed == 0) {
                revert PreviousValidTransactionNotExecuted(transaction.prev);
            }
        }
        
        transaction.executed = 1;

        for (uint256 i = 0; i < transaction.operations.length; ) {    
            (bool success, ) = transaction.operations[i].to.call{value: transaction.operations[i].value}(
                transaction.operations[i].data
            );
            if (!success) {
                revert TransactionCallFailed();
            }
            unchecked {
                ++i;
            }
        }

        emit ExecuteTransaction(index_);
    }

    /// @notice Transfers to operator the claimable amount of eth
    function operatorClaim() external onlyOperator {
        if (operatorClaimable == 0) {
            revert EmptyClaimableForOperator();
        }
        uint256 claimable = operatorClaimable;
        operatorClaimable = 0;
        address _owner = Ownable(tokenContractAddress).owner();
        emit Claim(_owner, claimable);
        payable(_owner).sendValue(claimable);
    }

    /// @notice Only protocol owner can submit a new transaction
    /// @param operation_: mapping of operations to be executed (could be just one or batch)
    /// @param description_: transaction description for easy read
    function submitTransaction(
        Operation[] calldata operation_,
        string calldata description_
    ) external onlyOperator {
        uint16 txLen = uint16(transactions.length);
        uint16 prev = type(uint16).max;
        uint16 next = type(uint16).max;

        if (txLen > 0) {
            prev = txLen - 1;
            Transaction storage transactionPrev = transactions[txLen - 1];
            transactionPrev.next = txLen;
        }

        transactions.push(Transaction({
            operations: operation_,
            executed: 0,
            confirmed: 0,
            valid: 1,
            prev: prev,
            next: next,
            description: description_
        }));

        emit SubmitTransaction(transactions.length, description_);
    }

    /// @notice For updating the exitDate
    /// @dev The exit date must be after the current exit date and it's only possible in validatorActive == true
    /// @param exitDate_ The new exit date
    function updateExitDate(uint64 exitDate_) external onlyOperator {
        if (!validatorActive) {
            revert ValidatorNotActive();
        }
        if (exitDate_ < exitDate) {
            revert NotEarlierThanOriginalDate();
        }
        if (exitDate_ > (exitDate + 720 days)) {
            revert IncrementTooHigh();
        }
        exitDate = exitDate_;
        emit ExitDateUpdated(exitDate_);
    }

    /// @notice Withdraw the deposit to a beneficiary
    /// @dev Is not possible to withdraw in validatorActive == true. Can only be called from the ERC721 contract
    /// @param beneficiary_ Who will receive the deposit
    function withdrawTo(address beneficiary_) external {
        // callable only from senseistake erc721 contract
        if (msg.sender != tokenContractAddress) {
            revert CallerNotAllowed();
        }
        if (validatorActive) {
            revert ValidatorIsActive();
        }
        uint256 amount = address(this).balance - operatorClaimable;
        emit Withdrawal(beneficiary_, amount);
        payable(beneficiary_).sendValue(amount);
    }

    /// @notice Get current transaction count
    /// @return count of transactions
    function getTransactionCount() public view returns (uint256) {
        return transactions.length;
    }

    /// @notice Get withdrawable amount of a user
    /// @return amount the depositor is allowed withdraw
    function getWithdrawableAmount() external view returns (uint256) {
        if (validatorActive) {
            return 0;
        }
        return address(this).balance - operatorClaimable;
    }
}
