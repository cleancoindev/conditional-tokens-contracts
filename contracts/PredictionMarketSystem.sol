pragma solidity ^0.5.1;
import { IERC20 } from "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import { IERC1155TokenReceiver } from "./ERC1155/IERC1155TokenReceiver.sol";
import { ERC1155 } from "./ERC1155/ERC1155.sol";
import { ERC1820Registry } from "./ERC1820Registry.sol";


contract ConditionalTokens is ERC1155 {

    /// @dev Emitted upon the successful preparation of a condition.
    /// @param conditionId The condition's ID. This ID may be derived from the other three parameters via ``keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount))``.
    /// @param oracle The account assigned to report the result for the prepared condition.
    /// @param questionId An identifier for the question to be answered by the oracle.
    /// @param outcomeSlotCount The number of outcome slots which should be used for this condition. Must not exceed 256.
    event ConditionPreparation(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint outcomeSlotCount
    );

    event ConditionResolution(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint outcomeSlotCount,
        uint[] payoutNumerators
    );

    /// @dev Emitted when a position is successfully split.
    event PositionSplit(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint[] partition,
        uint amount
    );
    /// @dev Emitted when positions are successfully merged.
    event PositionsMerge(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint[] partition,
        uint amount
    );
    event PayoutRedemption(
        address indexed redeemer,
        IERC20 indexed collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 conditionId,
        uint[] indexSets,
        uint payout
    );

    /// Mapping key is an condition ID. Value represents numerators of the payout vector associated with the condition. This array is initialized with a length equal to the outcome slot count.
    mapping(bytes32 => uint[]) public payoutNumerators;
    mapping(bytes32 => uint) public payoutDenominator;

    /// @dev This function prepares a condition by initializing a payout vector associated with the condition.
    /// @param oracle The account assigned to report the result for the prepared condition.
    /// @param questionId An identifier for the question to be answered by the oracle.
    /// @param outcomeSlotCount The number of outcome slots which should be used for this condition. Must not exceed 256.
    function prepareCondition(address oracle, bytes32 questionId, uint outcomeSlotCount) external {
        require(outcomeSlotCount <= 256, "too many outcome slots");
        require(outcomeSlotCount > 1, "there should be more than one outcome slot");
        bytes32 conditionId = keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
        require(payoutNumerators[conditionId].length == 0, "condition already prepared");
        payoutNumerators[conditionId] = new uint[](outcomeSlotCount);
        emit ConditionPreparation(conditionId, oracle, questionId, outcomeSlotCount);
    }

    /// @dev Called by the oracle for reporting results of conditions. Will set the payout vector for the condition with the ID ``keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount))``, where oracle is the message sender, questionId is one of the parameters of this function, and outcomeSlotCount is the length of the payouts parameter, which contains the payoutNumerators for each outcome slot of the condition.
    /// @param questionId The question ID the oracle is answering for
    /// @param payouts The oracle's answer
    function reportPayouts(bytes32 questionId, uint[] calldata payouts) external {
        require(payouts.length > 1, "there should be more than one outcome slot");
        bytes32 conditionId = keccak256(abi.encodePacked(msg.sender, questionId, payouts.length));
        require(payoutNumerators[conditionId].length == payouts.length, "condition not prepared or found");
        require(payoutDenominator[conditionId] == 0, "payout denominator already set");
        uint den = 0;
        for (uint i = 0; i < payouts.length; i++) {
            den = den.add(payouts[i]);

            require(payoutNumerators[conditionId][i] == 0, "payout numerator already set");
            payoutNumerators[conditionId][i] = payouts[i];
        }
        payoutDenominator[conditionId] = den;
        require(payoutDenominator[conditionId] > 0, "payout is all zeroes");
        emit ConditionResolution(conditionId, msg.sender, questionId, payouts.length, payoutNumerators[conditionId]);
    }

    /// @dev This function splits a position. If splitting from the collateral, this contract will attempt to transfer `amount` collateral from the message sender to itself. Otherwise, this contract will burn `amount` stake held by the message sender in the position being split. Regardless, if successful, `amount` stake will be minted in the split target positions. If any of the transfers, mints, or burns fail, the transaction will revert. The transaction will also revert if the given partition is trivial, invalid, or refers to more slots than the condition is prepared with.
    /// @param collateralToken The address of the positions' backing collateral token.
    /// @param parentCollectionId The ID of the outcome collections common to the position being split and the split target positions. May be null, in which only the collateral is shared.
    /// @param conditionId The ID of the condition to split on.
    /// @param partition An array of disjoint index sets representing a nontrivial partition of the outcome slots of the given condition.
    /// @param amount The amount of collateral or stake to split.
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint[] calldata partition,
        uint amount
    ) external {
        uint outcomeSlotCount = payoutNumerators[conditionId].length;
        require(outcomeSlotCount > 0, "condition not prepared yet");

        bytes32 key;

        uint fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint freeIndexSet = fullIndexSet;
        for (uint i = 0; i < partition.length; i++) {
            uint indexSet = partition[i];
            require(indexSet > 0 && indexSet < fullIndexSet, "got invalid index set");
            require((indexSet & freeIndexSet) == indexSet, "partition not disjoint");
            freeIndexSet ^= indexSet;
            key = keccak256(abi.encodePacked(collateralToken, getCollectionId(parentCollectionId, conditionId, indexSet)));
            _mint(msg.sender, uint(key), amount, "");
        }

        if (freeIndexSet == 0) {
            if (parentCollectionId == bytes32(0)) {
                require(collateralToken.transferFrom(msg.sender, address(this), amount), "could not receive collateral tokens");
            } else {
                key = keccak256(abi.encodePacked(collateralToken, parentCollectionId));
                _burn(msg.sender, uint(key), amount);
            }
        } else {
            key = keccak256(abi.encodePacked(collateralToken, getCollectionId(parentCollectionId, conditionId, fullIndexSet ^ freeIndexSet)));
            _burn(msg.sender, uint(key), amount);
        }

        emit PositionSplit(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint[] calldata partition,
        uint amount
    ) external {
        uint outcomeSlotCount = payoutNumerators[conditionId].length;
        require(outcomeSlotCount > 0, "condition not prepared yet");

        bytes32 key;

        uint fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint freeIndexSet = fullIndexSet;
        for (uint i = 0; i < partition.length; i++) {
            uint indexSet = partition[i];
            require(indexSet > 0 && indexSet < fullIndexSet, "got invalid index set");
            require((indexSet & freeIndexSet) == indexSet, "partition not disjoint");
            freeIndexSet ^= indexSet;
            key = keccak256(abi.encodePacked(collateralToken, getCollectionId(parentCollectionId, conditionId, indexSet)));
            _burn(msg.sender, uint(key), amount);
        }

        if (freeIndexSet == 0) {
            if (parentCollectionId == bytes32(0)) {
                require(collateralToken.transfer(msg.sender, amount), "could not send collateral tokens");
            } else {
                key = keccak256(abi.encodePacked(collateralToken, parentCollectionId));
                _mint(msg.sender, uint(key), amount, "");
            }
        } else {
            key = keccak256(abi.encodePacked(collateralToken, getCollectionId(parentCollectionId, conditionId, fullIndexSet ^ freeIndexSet)));
            _mint(msg.sender, uint(key), amount, "");
        }

        emit PositionsMerge(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function redeemPositions(IERC20 collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint[] calldata indexSets) external {
        uint den = payoutDenominator[conditionId];
        require(den > 0, "result for condition not received yet");
        uint outcomeSlotCount = payoutNumerators[conditionId].length;
        require(outcomeSlotCount > 0, "condition not prepared yet");

        uint totalPayout = 0;
        bytes32 key;

        uint fullIndexSet = (1 << outcomeSlotCount) - 1;
        for (uint i = 0; i < indexSets.length; i++) {
            uint indexSet = indexSets[i];
            require(indexSet > 0 && indexSet < fullIndexSet, "got invalid index set");
            key = keccak256(abi.encodePacked(collateralToken, getCollectionId(parentCollectionId, conditionId, indexSet)));

            uint payoutNumerator = 0;
            for (uint j = 0; j < outcomeSlotCount; j++) {
                if (indexSet & (1 << j) != 0) {
                    payoutNumerator = payoutNumerator.add(payoutNumerators[conditionId][j]);
                }
            }

            uint payoutStake = balanceOf(msg.sender, uint(key));
            if (payoutStake > 0) {
                totalPayout = totalPayout.add(payoutStake.mul(payoutNumerator).div(den));
                _burn(msg.sender, uint(key), payoutStake);
            }
        }

        if (totalPayout > 0) {
            if (parentCollectionId == bytes32(0)) {
                require(collateralToken.transfer(msg.sender, totalPayout), "could not transfer payout to message sender");
            } else {
                key = keccak256(abi.encodePacked(collateralToken, parentCollectionId));
                _mint(msg.sender, uint(key), totalPayout, "");
            }
        }
        emit PayoutRedemption(msg.sender, collateralToken, parentCollectionId, conditionId, indexSets, totalPayout);
    }

    /// @dev Gets the outcome slot count of a condition.
    /// @param conditionId ID of the condition.
    /// @return Number of outcome slots associated with a condition, or zero if condition has not been prepared yet.
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint) {
        return payoutNumerators[conditionId].length;
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint indexSet) private pure returns (bytes32) {
        return bytes32(
            uint(parentCollectionId) +
            uint(keccak256(abi.encodePacked(conditionId, indexSet)))
        );
    }

    // this value is meant to be used in a require(gasleft() >= CHECK_IS_RECEIVER_REQUIRED_GAS)
    // statement preceding an ERC165 introspection staticcall to verify that a contract is
    // an ERC1155TokenReceiver. Gas values gotten through experimenting with Remix.
    uint constant CHECK_IS_RECEIVER_REQUIRED_GAS =
        uint(10000) * 64 / 63 + 1 + // minimum gas required to exist before call opcode
        700 +                       // call cost
        564 +                       // cost for getting the stuff on the stack
        100;                        // cost for executing require statement itself

    bytes constant CHECK_IS_RECEIVER_CALLDATA = abi.encodeWithSignature(
        "supportsInterface(bytes4)",
        bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")) ^
        bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))
    );


    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    )
        internal
    {
        if(to.isContract()) {
            require(gasleft() >= CHECK_IS_RECEIVER_REQUIRED_GAS, "ERC1155: not enough gas reserved for token receiver check");
            (bool callSucceeded, bytes memory callReturnData) = to.call.gas(10000)(CHECK_IS_RECEIVER_CALLDATA);

            if(
                callSucceeded &&
                callReturnData.length > 0 &&
                abi.decode(callReturnData, (bool)) == true
            ) {
                require(
                    IERC1155TokenReceiver(to).onERC1155Received(operator, from, id, value, data) ==
                        IERC1155TokenReceiver(to).onERC1155Received.selector,
                    "ERC1155: got unknown value from onERC1155Received"
                );
            } else {
                address implementer = ERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24)
                    .getInterfaceImplementer(to, keccak256(bytes("ERC1155TokenReceiver")));

                if(implementer != address(0)) {
                    require(
                        IERC1155TokenReceiver(implementer).onERC1155Received(operator, from, id, value, data) ==
                            IERC1155TokenReceiver(implementer).onERC1155Received.selector,
                        "ERC1155: got unknown value from implemented onERC1155Received"
                    );
                }
            }
        }
    }

    function _doSafeBatchTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    )
        internal
    {
        if(to.isContract()) {
            require(gasleft() >= CHECK_IS_RECEIVER_REQUIRED_GAS, "ERC1155: not enough gas reserved for token receiver check");
            (bool callSucceeded, bytes memory callReturnData) = to.staticcall.gas(10000)(CHECK_IS_RECEIVER_CALLDATA);

            if(
                callSucceeded &&
                callReturnData.length > 0 &&
                abi.decode(callReturnData, (bool)) == true
            ) {
                require(
                    IERC1155TokenReceiver(to).onERC1155BatchReceived(operator, from, ids, values, data) ==
                        IERC1155TokenReceiver(to).onERC1155BatchReceived.selector,
                    "ERC1155: got unknown value from onERC1155BatchReceived"
                );
            } else {
                address implementer = ERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24)
                    .getInterfaceImplementer(to, keccak256(bytes("ERC1155TokenReceiver")));

                if(implementer != address(0)) {
                    require(
                        IERC1155TokenReceiver(implementer).onERC1155BatchReceived(operator, from, ids, values, data) ==
                            IERC1155TokenReceiver(implementer).onERC1155BatchReceived.selector,
                        "ERC1155: got unknown value from implemented onERC1155BatchReceived"
                    );
                }
            }
        }
    }
}
