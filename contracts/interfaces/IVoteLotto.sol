//SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


interface IVoteLotto {

    /**
     * @notice Buy tickets for the current lotto
     * @param _lottoId: lotteryId
     * @param _ticketNumbers: array of ticket numbers between 1,000,000 and 1,999,999
     * @dev Callable by users
     */
    function buyTickets(uint256 _lottoId, uint32[] calldata _ticketNumbers, address _tokenVote) payable external;

    /**
     * @notice Claim a set of winning tickets for a lottery
     * @param _lottoId: lottery id
     * @param _ticketIds: array of ticket ids
     * @param _tiers: array of tiers for the ticket ids
     * @dev Callable by users only, not contract!
     */
    function claimTickets(
        uint256 _lottoId,
        uint256[] calldata _ticketIds,
        uint32[] calldata _tiers
    ) external;

    /**
     * @notice Close lottery
     * @param _lottoId: lottery id
     * @dev Callable by operator
     */
    function closeLotto(uint256 _lottoId) external;

    /**
     * @notice Draw the final number, calculate reward in CAKE per group, and make lottery claimable
     * @param _lottoId: lottery id
     * @param _autoInjection: reinjects funds into next lottery (vs. withdrawing all)
     * @dev Callable by operator
     */
    function drawFinalNumberAndClaim(uint256 _lottoId, bool _autoInjection) external;

    /**
     * @notice Inject funds
     * @param _lottoId: lottery id
     * @param _amount: amount to inject in CAKE token
     * @dev Callable by operator
     */
    function injectFunds(uint256 _lottoId, uint256 _amount) external;

    /**
     * @notice Start the lottery
     * @dev Callable by operator
     * @param _endTime: endTime of the lotto
     * @param _ticketPrice: price of a ticket in CAKE
     * @param _discountTier: the divisor to calculate the discount magnitude for bulks
     * @param _tierCalc: breakdown of rewards per bracket (must sum to 10,000)
     * @param _treasuryFee: treasury fee (10,000 = 100%, 100 = 1%)
     */
    function startLotto(
        uint256 _endTime,
        uint256 _ticketPrice,
        uint256 _discountTier,
        uint256[6] calldata _tierCalc,
        uint256 _treasuryFee,
        uint256 _gmFee
    ) external;

    /**
     * @notice View current lotto id
     */
    function getCurrentLottoId() external returns (uint256);
}