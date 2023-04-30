//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IEqualizerRouter.sol";
import "./interfaces/IRandomNumberGenerator.sol";
import "./interfaces/IVoteLotto.sol";

contract VoteLotto is ReentrancyGuard, IVoteLotto, Ownable {
    using SafeERC20 for IERC20;

    //EVENTS
    event StuckToken(address token, uint256 amount);
    event LottoOngoing(uint256 indexed lottoId, uint256 indexed firstTicketIdNextLotto);
    event PotInjection(uint256 indexed lottoId, uint256 indexed injectedAmount);
    event LottoOpen(
        uint256 indexed lottoId,
        uint256 startTime,
        uint256 endTime,
        uint256 ticketPrice,
        uint256 firstTicketId,
        uint256 injectedAmount
    );
    event LottoClose(uint256 indexed lottoId, uint256 indexed firstTicketIdNextLotto, address indexed winningToken);
    event NumberDrawnVotesCounted(uint256 indexed lottoId, uint256 finalNumber, uint256 countWinningTickets, address winningToken);
    event NewGameMaster(address indexed gameMaster);
    event NewTreasury(address indexed treasury);
    event NewOperator(address indexed operator);
    event NewRandomGenerator(address indexed randomGenerator);
    event TicketPurchase(address indexed buyer, uint256 indexed lottoId, uint256 numberOfTickets, address indexed tokenVote);
    event TicketClaimed(address indexed claimer, uint256 indexed amount, uint256 indexed lottoId);
    event Whitelisted(address indexed token);
    event PotSwap(uint256 indexed lottoId, address indexed winningToken, uint256 indexed pot);

    enum Status{
        Pending,
        Ongoing,
        Closed,
        Claimable
    }

    //Protocol addresses
    address public gameMaster; //Owner
    address public treasury;
    address public operator;
    //3rd party Addresses
    address public router;
    address private constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    //Lotto Variables
    uint256 public currentLottoId; 
    uint256 public currentTicketId;
    uint256 private pendingInjectionNextLotto;
    uint256 public maxTickets = 100;
    uint256 public ticketPrice;
    uint256 public maxTicketPrice = 500;
    uint256 public minTicketPrice = 5;

    uint256 public constant LOTTO_MIN_LENGTH = 1 days - 5 minutes; //1D
    uint256 public constant LOTTO_MAX_LENGTH  = 7 days + 5 minutes; //7D
    uint256 public constant MIN_DISCOUNT_TIER = 300;
    uint256 public constant MAX_GM_FEE = 200; //%
    uint256 public constant MAX_TREASURY_FEE = 200; //30%
    
    struct Lotto {
        Status status;
        uint256 totalVotes;
        address winningToken;
        uint32 finalNumber;
        uint256 startTime;
        uint256 endTime;
        uint256 ticketPrice;
        uint256 treasuryFee;
        uint256 gmFee;
        uint256 firstTicketId;
        uint256 firstTicketIdNextLotto;
        uint256 pot;
        uint256 discountTier;
        uint256[6] rewardTiers;
        uint256[6] winnersPerTier;
        uint256[6] awardPerTier;
    }

    struct Ticket{
        uint32 number;
        address owner;
        address tokenVote;
    }

    struct WlTokens{
    address[] tokens;
    mapping(address => IEqualizerRouter.Routes[]) paths;
    mapping(address => uint) votes;
    mapping(address => bool) isWL;
    }

    IRandomNumberGenerator public randomGenerator;
    WlTokens private _wlTokens;

    //map lottoId to lotto and ticket
    mapping(uint256 => Lotto) private _lottos;
    mapping(uint256 => Ticket) private _tickets;
    //Verify claims for ticket prizes
    mapping(uint256 => uint32) private _tierCalc;
    //keep track of nr of tickets per unique combination for each lotto
    mapping(uint256 => mapping(uint32 => uint256)) private _ticketsPerLottoId;
    //keep track of user ticket ids for a given lottoId
    mapping(address => mapping(uint256 => uint256[])) private _userTicketIdsPerLottoId;

    constructor(
        address _randomGeneratorAddress, 
        address _router,
        address _treasury
    ) {
        gameMaster = msg.sender;
        randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);
        router = _router;
        treasury = _treasury;
        
        _tierCalc[0] = 1;
        _tierCalc[1] = 11;
        _tierCalc[2] = 111;
        _tierCalc[3] = 1111;
        _tierCalc[4] = 11111;
        _tierCalc[5] = 111111;
    }

    //USER FUNCTIONS//
    function buyTickets(uint256 _lottoId, uint32[] calldata _ticketNumbers, address _tokenVote) override external nonReentrant{
        require(msg.sender == tx.origin, "Contract");
        require(_ticketNumbers.length != 0, "Specify a ticket");
        require(_ticketNumbers.length <= maxTickets, "< 100 tickets");
        require(_wlTokens.isWL[_tokenVote], "Token !WL");
        require(_lottos[_lottoId].status == Status.Ongoing, "Lotto !ongoing");
        require(block.timestamp < _lottos[_lottoId].endTime, "Lotto finished");

        uint256 finalPrice = _calcFinalPrice(_lottos[_lottoId].discountTier, _lottos[_lottoId].ticketPrice, _ticketNumbers.length);
        payable(msg.sender).transfer(finalPrice);

        _lottos[_lottoId].pot += finalPrice;
        _lottos[_lottoId].totalVotes += _ticketNumbers.length;
        _wlTokens.votes[_tokenVote] += _ticketNumbers.length;

        for(uint256 i = 0; i < _ticketNumbers.length; ++i) {
            uint32 thisTicketNumber = _ticketNumbers[i];

            require((thisTicketNumber >= 1000000) &&(thisTicketNumber <= 199999), "!Range");

            _ticketsPerLottoId[_lottoId][1 + (thisTicketNumber % 10)]++;
            _ticketsPerLottoId[_lottoId][11 + (thisTicketNumber % 100)]++;
            _ticketsPerLottoId[_lottoId][111 + (thisTicketNumber % 1000)]++;
            _ticketsPerLottoId[_lottoId][1111 + (thisTicketNumber % 10000)]++;
            _ticketsPerLottoId[_lottoId][11111 + (thisTicketNumber % 100000)]++;
            _ticketsPerLottoId[_lottoId][111111 + (thisTicketNumber % 1000000)]++;

            _userTicketIdsPerLottoId[msg.sender][_lottoId].push(currentTicketId);

            _tickets[currentTicketId] = Ticket({number: thisTicketNumber, owner: msg.sender, tokenVote: _tokenVote});

            ++currentTicketId;
        }
        emit TicketPurchase(msg.sender, _lottoId, _ticketNumbers.length, _tokenVote);
    }

    function claimTickets(uint256 _lottoId, uint256[] calldata _ticketIds, uint32[] calldata _tiers) external override nonReentrant{
        require(msg.sender == tx.origin, "Contract");
        require(_ticketIds.length == _tiers.length, "!= length");
        require(_ticketIds.length != 0, "!Length > 0");
        require(_ticketIds.length <= maxTickets, "> ticket limit");
        require(_lottos[_lottoId].status == Status.Claimable, "!Claimable");

        uint256 awardToTransfer;

        for(uint256 i = 0; i < _ticketIds.length; ++i) {
            require(_tiers[i] < 6, "Outside range");
            uint256 thisTicketId = _ticketIds[i];

            require(_lottos[_lottoId].firstTicketIdNextLotto > thisTicketId, "High ID");
            require(_lottos[_lottoId].firstTicketId < thisTicketId, "Low ID");
            require(msg.sender == _tickets[thisTicketId].owner, "!Owner");

            _tickets[thisTicketId].owner = address(0); //Update ticket owner to 0x

            uint256 rewardForTicketId = _calcRewardForTicketId(_lottoId, thisTicketId, _tiers[i]); //Calc reward

            require(rewardForTicketId != 0, "!prize in tier"); //check correct tier

            if(_tiers[i] !=5) {
                require(_calcRewardForTicketId(_lottoId, thisTicketId, _tiers[i] +1) == 0, "Tier !>");
            }
            awardToTransfer += rewardForTicketId; //add reward to transfer

            //transfer to user

            emit TicketClaimed(msg.sender, awardToTransfer, _lottoId);
        }
    }

    //ADMIN//
    function startLotto(uint256 _endTime, uint256 _ticketPrice, uint256 _discountTier, uint256[6] calldata _rewardTiers, uint256 _treasuryFee, uint256 _gmFee) external override onlyGMorOperator {
        require((currentLottoId == 0 ) || (_lottos[currentLottoId].status == Status.Claimable), "!start");
        require(((_endTime - block.timestamp) > LOTTO_MIN_LENGTH) && ((_endTime - block.timestamp) < LOTTO_MAX_LENGTH), "Length off range");
        require((_ticketPrice >= minTicketPrice) && (_ticketPrice <= maxTicketPrice), "> Price");
        require(_discountTier >= MIN_DISCOUNT_TIER, "Low Discount");
        require((_treasuryFee <= MAX_TREASURY_FEE) &&(_gmFee <= MAX_GM_FEE), "High Fee");
        require((_rewardTiers[0] + _rewardTiers[1] + _rewardTiers[2] + _rewardTiers[3] + _rewardTiers[4] + _rewardTiers[5]) == 10000, "!= 10000");

        ++currentLottoId;
        
        _lottos[currentLottoId] = Lotto({
            status: Status.Ongoing,
            winningToken: address(0),
            totalVotes: 0,
            finalNumber: 0,
            startTime: block.timestamp,
            endTime: _endTime,
            ticketPrice: _ticketPrice,
            discountTier: _discountTier,
            treasuryFee: _treasuryFee,
            gmFee: _gmFee,
            rewardTiers: [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
            awardPerTier: [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
            winnersPerTier: [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
            firstTicketId: currentTicketId,
            firstTicketIdNextLotto: currentTicketId,
            pot: pendingInjectionNextLotto
        });
        emit LottoOpen(currentLottoId, block.timestamp, _endTime, _ticketPrice, currentTicketId, pendingInjectionNextLotto);

        pendingInjectionNextLotto = 0;
    }

    function closeLotto(uint256 _lottoId) external override onlyGMorOperator nonReentrant {
        require(_lottos[_lottoId].status == Status.Ongoing, "!Ongoing");
        require(block.timestamp > _lottos[_lottoId].endTime, "Ongoing");
        _lottos[_lottoId].firstTicketIdNextLotto = currentLottoId;

        //Assign winning Token
        _lottos[_lottoId].winningToken = _getWinVote();
        if(_getWinVote() == wftm){
           //DISTRO REWARDS
        } else {
            _swapPot(_getWinVote());
            //DISTRO REWARDS
        }

        //Get VRF number
        randomGenerator.getRandomNumber(_lottoId);
        _lottos[_lottoId].status == Status.Closed;

        emit LottoClose(_lottoId, currentTicketId, _lottos[_lottoId].winningToken);
    }

    function drawFinalNumberAndClaim(uint256 _lottoId, bool _autoInjection) external override onlyGMorOperator nonReentrant {
        require(_lottos[_lottoId].status == Status.Closed, "!Closed");
        require(_lottoId == randomGenerator.viewLatestLottoId(), "!Drawn");
        //calc finalNumber based on chainlink's VRF
        uint32 finalNumber = randomGenerator.viewRandomResult();
        //count addresses in previous tier
        uint256 numberAddressesInPreviousTier;
        //amount to share post treasury+gm fees
        uint256 amountToRewardWinners = (_lottos[_lottoId].pot * ((1000 - _lottos[_lottoId].treasuryFee) + (1000 - _lottos[_lottoId].gmFee)));
        //amount to withdraw to treasury and gm
        uint256 amountToTreasury;
        uint256 amountToGM;
        //calc prizes for each tier starting with highest one
        for(uint32 i = 0; i < 6; ++i){
            uint32 j = 5 - i;
            uint32 transformedWinningNumber = _tierCalc[i] + (finalNumber %(uint32(10)**(j + 1)));
            _lottos[_lottoId].winnersPerTier[j] = _ticketsPerLottoId[_lottoId][transformedWinningNumber] - numberAddressesInPreviousTier;

            //If number of users for this _tier number is > 0
            if((_ticketsPerLottoId[_lottoId][transformedWinningNumber] - numberAddressesInPreviousTier) != 0){
                //If rewards at this tier are > 0, calc else, report numberAddresses from previous tier
                if(_lottos[_lottoId].rewardTiers[j] !=0){
                    _lottos[_lottoId].awardPerTier[j] = 
                    ((_lottos[_lottoId].rewardTiers[j] * amountToRewardWinners) / (_ticketsPerLottoId[_lottoId][transformedWinningNumber] - numberAddressesInPreviousTier)) / 20000;
                    //update numberAddressesInPreviousTier
                    numberAddressesInPreviousTier = _ticketsPerLottoId[_lottoId][transformedWinningNumber];   
                    //If there is none to distro, it's added to the amount to withdraw to treasury/GM                 
                } else {
                    _lottos[_lottoId].awardPerTier[j] = 0;
                    amountToTreasury += (_lottos[_lottoId].rewardTiers[j] * amountToRewardWinners) / 1000;
                    amountToGM = amountToTreasury;
                }
            }
        }

        //Update Statuses for Lotto
        _lottos[_lottoId].finalNumber = finalNumber;
        _lottos[_lottoId].status = Status.Claimable;

        if(_autoInjection) {
            pendingInjectionNextLotto = amountToTreasury;
            amountToTreasury = 0;
        }
        amountToGM += ((_lottos[_lottoId].pot - amountToRewardWinners) / 2);
        amountToTreasury = amountToGM;

        IERC20(wftm).transfer(gameMaster, amountToGM);
        IERC20(wftm).transfer(treasury, amountToTreasury);
        emit NumberDrawnVotesCounted(_lottoId, finalNumber, numberAddressesInPreviousTier, _lottos[_lottoId].winningToken);
    }

    function addToWL(IEqualizerRouter.Routes[] memory _path, address _token) external onlyOwner{
        require(!_wlTokens.isWL[address(_token)], "Exists");
        for (uint i; i < _path.length; ++i) {
            _wlTokens.paths[_token].push(_path[i]);
        }
        _wlTokens.tokens.push(_token);
        _wlTokens.isWL[_token] = true;
        emit Whitelisted (_token);
    }

    function changeRandomGenerator(address _randomGeneratorAddress) external onlyOwner {
        require(_lottos[currentLottoId].status == Status.Claimable, "!Claimable");

        //Request RNG from generator based on a seed
        IRandomNumberGenerator(_randomGeneratorAddress).getRandomNumber(
            uint256(keccak256(abi.encodePacked(currentLottoId, currentTicketId)))
            );

        //Calc finalNumber based randomResult
        IRandomNumberGenerator(_randomGeneratorAddress).viewRandomResult();
        randomGenerator = IRandomNumberGenerator(_randomGeneratorAddress);
        emit NewRandomGenerator(_randomGeneratorAddress);
    }
    
    //HELPERS & UTILS//
    function injectFunds(uint256 _lottoId, uint256 _amount) external override {
        require(_lottos[_lottoId].status == Status.Ongoing, "!Ongoing");
        IERC20(wftm).safeTransfer(msg.sender, _amount);
        _lottos[_lottoId].pot += _amount;
        emit PotInjection(_lottoId, _amount);
    }

    function stuckToken(address _tokenAddress, uint256 _tokenAmount) external onlyGMorOperator{
        require(_tokenAddress != wftm, "Token");  
        IERC20(_tokenAddress).transfer(address(msg.sender), _tokenAmount);
        emit StuckToken(_tokenAddress, _tokenAmount); 
    }

    function setMinMaxPrice(uint256 _minPrice, uint256 _maxPrice) external onlyGMorOperator{
        require(_minPrice <= _maxPrice, "minPrice < maxPrice");
        minTicketPrice = _minPrice;
        maxTicketPrice = _maxPrice;
    }

    function setGameMaster(address _gameMaster) external {
        require(_gameMaster != address(0) && msg.sender == gameMaster,"auth");
        gameMaster = _gameMaster;
        emit NewGameMaster(_gameMaster);
    }

    function setTreasury(address _treasury) external onlyOwner{
        require(_treasury != address(0), "0");
        treasury = _treasury;
        emit NewTreasury(_treasury);
    }

    function setOperator(address _operator) external onlyOwner{
        require(_operator != address(0), "0");
        operator = _operator;
        emit NewOperator(_operator);
    }

    function setMaxTickets(uint256 _maxTickets) external onlyGMorOperator{
        require(_maxTickets != 0, "!> 0");
        maxTickets = _maxTickets;
    }

    //INTERNAL//
    function _swapPot(address _token) internal {
        uint256 pot = IERC20(_token).balanceOf(address(this));
        approvalCheck(router, _token, pot);
        IEqualizerRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(pot, 1, _wlTokens.paths[_token], address(this), block.timestamp);
        emit PotSwap(currentLottoId, _token, pot);
    }

    function approvalCheck(address _spender, address _token, uint256 _amount) internal {
        if (IERC20(_token).allowance(_spender, address(this)) < _amount) {
            IERC20(_token).approve(_spender, 0);
            IERC20(_token).approve(_spender, _amount);
        }
    }

    function _getVotes(address _token) internal view returns (uint){
        return _wlTokens.votes[_token];
    }

    function _getWinVote() internal view returns (address){ 
    uint mostVotes;
    bool tie;
    uint addrIndex;

    for(uint i = 0; i < _wlTokens.tokens.length; ++i){
        uint votes = _getVotes(_wlTokens.tokens[i]);
        if(votes == mostVotes && votes != 0){
            tie = true;
        } else if (votes > mostVotes) {
            mostVotes = votes;
            addrIndex = i;
            tie = false;
        }
    }
    if (tie == true) {
        return wftm; } else { return _wlTokens.tokens[addrIndex];}
    }

    function _calcFinalPrice(uint256 _discountTier, uint256 _ticketPrice, uint256 _numberTickets) internal pure returns(uint256){
        return(_ticketPrice * _numberTickets * (_discountTier) + 1 - _numberTickets) / _discountTier;
    }

    function _calcRewardForTicketId(uint256 _lottoId, uint256 _ticketId, uint32 _tier) internal view returns(uint256){
        uint32 userNumber = _lottos[_lottoId].finalNumber; //Get winning nr combo
        uint32 winningTicketNumber = _tickets[_ticketId].number; //Get user nr combo
        //Apply transformation to verify claim
        uint32 transformedWinningNumber = _tierCalc[_tier] + (winningTicketNumber % (uint32(10)**(_tier +1)));
        uint32 transformedUserNumber = _tierCalc[_tier] + (userNumber % (uint32(10)**(_tier +1)));
        //Confirm transformed numbers are the same
        if(transformedWinningNumber == transformedUserNumber){
            return _lottos[_lottoId].awardPerTier[_tier];
        } else {
            return 0;
        }
    }

    //VIEW FUNCTIONS//
    function getWL() external view returns(address[] memory) {return _wlTokens.tokens;}

    function potBalance() external view returns(uint256) {return IERC20(wftm).balanceOf(address(this));}

    function getCurrentLottoId() external override view returns (uint256) {return currentLottoId;}

    function lottoInfo(uint256 _lottoId) external view returns (Lotto memory) {return _lottos[_lottoId];}

    function calcFinalPrice(uint256 _discountTier, uint256 _ticketPrice, uint256 _numberTickets) external pure returns(uint256){
        require(_discountTier >= MIN_DISCOUNT_TIER, "!> minDiscount");
        require(_numberTickets != 0, ">= 1 Ticket");

        return(_calcFinalPrice(_discountTier, _ticketPrice, _numberTickets));
    }

    function viewNumbersAndStatusesForTicketIds(uint256[] calldata _ticketIds) external view returns(uint32[] memory, bool[] memory){
        uint256 length = _ticketIds.length;
        uint32[] memory ticketNumbers = new uint32[](length);
        bool[] memory ticketStatuses = new bool[](length);

        for(uint256 i = 0; i < length; ++i){
            ticketNumbers[i] = _tickets[_ticketIds[i]].number;
            if(_tickets[_ticketIds[i]].owner == address(0)){
                ticketStatuses[i] = true;
            } else {
                ticketStatuses[i] = false;
            }
        }
        return(ticketNumbers, ticketStatuses);
    }

    function viewRewardforTicketId(uint256 _lottoId, uint256 _ticketId, uint32 _tier) external view returns(uint256){
        //Check if VoteLotto is Claimable
        if(_lottos[_lottoId].status != Status.Claimable){return 0;}
        //Check tickedIt in range
        if((_lottos[_lottoId].firstTicketIdNextLotto < _ticketId) && (_lottos[_lottoId].firstTicketId >= _ticketId)){return 0;}

        return _calcRewardForTicketId(_lottoId, _ticketId, _tier);
    }

    function getUserInfoForLottoId(address _user, uint256 _lottoId, uint256 _cursor, uint256 _size) external view returns(uint256[] memory, uint32[] memory, bool[] memory, uint256) {
        uint256 length = _size;
        uint256 numberTicketsBoughtAtLottoId = _userTicketIdsPerLottoId[_user][_lottoId].length;

        if(length > (numberTicketsBoughtAtLottoId - _cursor)) { length = numberTicketsBoughtAtLottoId - _cursor;}

        uint256[] memory lottoTicketIds = new uint256[](length);
        uint32[] memory ticketNumbers = new uint32[](length);
        bool[] memory ticketStatuses = new bool[](length);
   
        for (uint256 i = 0; i < length; ++i){
        lottoTicketIds[i] = _userTicketIdsPerLottoId[_user][_lottoId][i + _cursor];
        ticketNumbers[i] = _tickets[lottoTicketIds[i]].number;

        //true = ticket claimed
        if(_tickets[lottoTicketIds[i]].owner == address(0)){
            ticketStatuses[i] = true;
        } else {
            //ticket not claimed (inc ones that can't be)
            ticketStatuses[i] = false;
        }
        }
        return (lottoTicketIds, ticketNumbers, ticketStatuses, _cursor + length);
    }

    //ACCESS CONTROL//
    modifier onlyGMorOperator(){
        require((msg.sender == gameMaster || msg.sender == operator), "auth");
        _;
    }

}

    