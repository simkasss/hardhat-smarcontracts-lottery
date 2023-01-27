// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol"; // from this we get checkUpkeep and performUpkeep

error Raffle__NotEnoughETHEntered();
error Raffle__TransferFailed();
error Raffle__NotOpen();
error Raffle__UpkeepNotNeeded(
    uint256 currentBalance,
    uint256 numPlayers,
    uint256 raffleState
);
error Raffle_CantExit();

/** @title A sample Raffle Contract
 * @author Simona Kastantinaviciute
 * @notice This contract is for creating an untamperable decentralized smart contract
 * @dev This implements Chainlink VRF v2 and Chainlink Keepers
 */

contract Raffle is VRFConsumerBaseV2, KeeperCompatibleInterface {
    enum RaffleState {
        OPEN,
        CALCULATING
    }

    uint256 private immutable i_entranceFee;
    address payable[] private s_players;
    mapping(address => uint256) private playerToFundedAmount;
    mapping(address => int256) private playerToIndex;
    int256 private s_index;
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_gasLine;
    uint64 private immutable i_subscriptionId;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private immutable i_callbackGasLimit;
    uint32 private constant NUM_WORDS = 1;

    address private s_recentWinner;
    RaffleState private s_raffleState;
    uint256 private s_lastTimeStamp;
    uint256 private immutable i_interval;

    event RaffleEnter(address indexed player);
    event RequestedRaffleWinner(uint256 indexed requestId);
    event WinnerPicked(address indexed winner);
    event RaffleLeft(address indexed player);

    constructor(
        address vrfCoordinatorV2,
        uint256 entranceFee,
        bytes32 gasLine,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        uint256 interval
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_entranceFee = entranceFee;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_gasLine = gasLine;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp; ////block.timestamp is global variable that returns current timestamp
        i_interval = interval;
        s_index = -1;
    }

    function enterRaffle() public payable {
        if (msg.value < i_entranceFee) {
            revert Raffle__NotEnoughETHEntered();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__NotOpen();
        }

        s_players.push(payable(msg.sender));
        s_index = s_index + 1;
        playerToIndex[msg.sender] = s_index;
        playerToFundedAmount[msg.sender] += msg.value;

        emit RaffleEnter(msg.sender);
    }

    function exitRaffle() public payable {
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval);
        bool playerHasFunded = (playerToFundedAmount[msg.sender] > 0);
        bool hasEnoughPlayers = (s_players.length >= 3);

        if (timePassed && playerHasFunded && !hasEnoughPlayers) {
            uint256 balance = playerToFundedAmount[msg.sender];
            playerToFundedAmount[msg.sender] = 0;
            (bool success, ) = msg.sender.call{value: balance}("");

            if (!success) {
                revert Raffle__TransferFailed();
            }
            s_index = playerToIndex[msg.sender];
            remove(uint256(s_index));
        } else {
            revert Raffle_CantExit();
        }
        emit RaffleLeft(msg.sender);
    }

    // Chainlink Keeper nodes call this function, they look for the 'upkeepNeeded' to be true
    // We define what should happen so that 'upkeepNeeded' would be true
    function checkUpkeep(
        bytes memory /*checkData*/
    )
        public
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        // all defined bools have to be true for upkeepNeeded to be true
        bool isOpen = (RaffleState.OPEN == s_raffleState);
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval); //block.timestamp is global variable that returns current timestamp
        bool hasEnoughPlayers = (s_players.length >= 3);
        bool hasBalance = address(this).balance > 0;
        upkeepNeeded = (isOpen &&
            timePassed &&
            hasEnoughPlayers &&
            hasBalance); /* this will be true or false*/
    }

    // if checkUpkeep returns true, this function gets executed (Chainlink nodes automatically calls it)
    function performUpkeep(
        bytes calldata /** performData */
    ) external override {
        //we want the function to be called only if upkeepNeeded (from checkUpkeep) is true
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_raffleState)
            );
        }

        s_raffleState = RaffleState.CALCULATING;
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLine,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            NUM_WORDS
        );
        emit RequestedRaffleWinner(requestId);
    }

    function fulfillRandomWords(
        uint256 /* requestId */,
        uint256[] memory randomWords
    ) internal override {
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner;
        s_raffleState = RaffleState.OPEN; //After we picked a winner we have to reset the Status of the raffle
        s_players = new address payable[](0); //After we picked a winner we have to reset the array
        s_lastTimeStamp = block.timestamp; //After we picked a winner we have to reset the timestamp
        (bool success, ) = recentWinner.call{value: address(this).balance}("");
        if (!success) {
            revert Raffle__TransferFailed();
        }
        emit WinnerPicked(recentWinner);
    }

    function remove(uint256 index) public {
        require(s_players.length > index, "Out of bounds");
        // move all elements to the left, starting from the `index + 1`
        for (uint256 i = index; i < s_players.length - 1; i++) {
            s_players[i] = s_players[i + 1];
        }
        s_players.pop(); // delete the last item
    }

    function getEntranceFee() public view returns (uint256) {
        return i_entranceFee;
    }

    function getPlayer(uint256 index) public view returns (address) {
        return s_players[index];
    }

    function getPlayerIndex(address player) public view returns (int256) {
        return playerToIndex[player];
    }

    function getRecentWinner() public view returns (address) {
        return s_recentWinner;
    }

    function getRaffleState() public view returns (RaffleState) {
        return s_raffleState;
    }

    function getNumWords() public pure returns (uint256) {
        return NUM_WORDS;
    }

    function getNumberOfPlayers() public view returns (uint256) {
        return s_players.length;
    }

    function getLatestTimeStamp() public view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getRequestConfirmations() public pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    function getInterval() public view returns (uint256) {
        return i_interval;
    }
}
