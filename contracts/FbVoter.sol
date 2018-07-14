pragma solidity ^0.4.23;

import 'openzeppelin-solidity/contracts/math/SafeMath.sol';
import 'openzeppelin-solidity/contracts/token/ERC20/StandardToken.sol';
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import 'contracts/DLL.sol';
import 'contracts/AttributeStore.sol';

contract FbVoter {

    // ------
    // EVENTS
    // ------

    event _Application(bytes32 indexed listingHash, uint deposit, uint appEndDate, string data, address indexed applicant);
    event _Challenge(bytes32 indexed listingHash, uint challengeID, string data, uint commitEndDate, uint revealEndDate, address indexed challenger);
    event _Deposit(bytes32 indexed listingHash, uint added, uint newTotal, address indexed owner);
    event _Withdrawal(bytes32 indexed listingHash, uint withdrew, uint newTotal, address indexed owner);
    event _ApplicationWhitelisted(bytes32 indexed listingHash);
    event _ApplicationRemoved(bytes32 indexed listingHash);
    event _ListingRemoved(bytes32 indexed listingHash);
    event _ListingWithdrawn(bytes32 indexed listingHash);
    event _TouchAndRemoved(bytes32 indexed listingHash);
    event _ChallengeFailed(bytes32 indexed listingHash, uint indexed challengeID, uint rewardPool, uint totalTokens);
    event _ChallengeSucceeded(bytes32 indexed listingHash, uint indexed challengeID, uint rewardPool, uint totalTokens);
    event _RewardClaimed(uint indexed challengeID, uint reward, address indexed voter);

    using SafeMath for uint;

    struct Listing {
        uint applicationExpiry; // Expiration date of apply stage
        bool whitelisted;       // Indicates registry status
        address owner;          // Owner of Listing
        uint unstakedDeposit;   // Number of tokens in the listing not locked in a challenge
        uint challengeID;       // Corresponds to a PollID in PLCRVoting
    }

    struct Challenge {
        uint rewardPool;        // (remaining) Pool of tokens to be distributed to winning voters
        address challenger;     // Owner of Challenge
        bool resolved;          // Indication of if challenge is resolved
        uint stake;             // Number of tokens at stake for either party during challenge
        uint totalTokens;       // (remaining) Number of tokens used in voting by the winning side
        mapping(address => bool) tokenClaims; // Indicates whether a voter has claimed a reward yet
    }

    // Maps challengeIDs to associated challenge data
    mapping(uint => Challenge) public challenges;

    // Maps listingHashes to associated listingHash data
    mapping(bytes32 => Listing) public listings;

    // Global Variables
    ERC20 public token;


    PLCRVoting public voting;

  	struct Poll {
		// [FIXME] [FIXME] WARNING - THIS STRUCT MUST BE EXACTLY COPIED FROM PLCRVoting contract!!!!
        uint commitEndDate;     /// expiration date of commit period for poll
        uint revealEndDate;     /// expiration date of reveal period for poll
        uint voteQuorum;	    /// number of votes required for a proposal to pass
        uint votesFor;		    /// tally of votes supporting proposal
        uint votesAgainst;      /// tally of votes countering proposal
        mapping(address => bool) didCommit;  /// indicates whether an address committed a vote for this poll
        mapping(address => bool) didReveal;   /// indicates whether an address revealed a vote for this poll
    }


	// [FIXME] CONFIG VARIABLES
	uint minDeposit = 10;
	uint pMinDeposit = 100;                                                                                                                                                  
	uint applyStageLen = 600;                                                                                                                                             
	uint pApplyStageLen = 1200;                                                                                                                                           
	uint commitStageLen = 600;                                                                                                                                            
	uint pCommitStageLen = 1200;                                                                                                                                          
	uint revealStageLen = 600;                                                                                                                                            
	uint pRevealStageLen = 1200;                                                                                                                                          
	uint dispensationPct = 50;                                                                                                                                               
	uint pDispensationPct = 50;                                                                                                                                              
	uint voteQuorum = 50;                                                                                                                                                    
	uint pVoteQuorum = 50;                                                                                                                                                    







	string public name;

    /**
    @dev Initializer. Can only be called once.
    @param _token The address where the ERC20 token contract is deployed
    */
    function init(address _token, address _voting, string _name) public {
        require(_token != 0 && address(token) == 0);
        require(_voting != 0 && address(voting) == 0);

        token = ERC20(_token);
        voting = PLCRVoting(_voting);
        name = _name;
    }

    // --------------------
    // PUBLISHER INTERFACE:
    // --------------------

    /**
    @dev                Allows a user to start an application. Takes tokens from user and sets
                        apply stage end time.
    @param _listingHash The hash of a potential listing a user is applying to add to the registry
    @param _amount      The number of ERC20 tokens a user is willing to potentially stake
    @param _data        Extra data relevant to the application. Think IPFS hashes.
    */
    function apply(bytes32 _listingHash, uint _amount, string _data) external {
        require(!isWhitelisted(_listingHash));
        require(!appWasMade(_listingHash));
        require(_amount >= minDeposit);

        // Sets owner
        Listing storage listing = listings[_listingHash];
        listing.owner = msg.sender;

        // Sets apply stage end time
        listing.applicationExpiry = block.timestamp.add(applyStageLen);
        listing.unstakedDeposit = _amount;

        // Transfers tokens from user to Registry contract
        require(token.transferFrom(listing.owner, this, _amount));

        emit _Application(_listingHash, _amount, listing.applicationExpiry, _data, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to increase their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of
    @param _amount      The number of ERC20 tokens to increase a user's unstaked deposit
    */
    function deposit(bytes32 _listingHash, uint _amount) external {
        Listing storage listing = listings[_listingHash];

        require(listing.owner == msg.sender);

        listing.unstakedDeposit += _amount;
        require(token.transferFrom(msg.sender, this, _amount));

        emit _Deposit(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to decrease their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of.
    @param _amount      The number of ERC20 tokens to withdraw from the unstaked deposit.
    */
    function withdraw(bytes32 _listingHash, uint _amount) external {
        Listing storage listing = listings[_listingHash];

        require(listing.owner == msg.sender);
        require(_amount <= listing.unstakedDeposit);
        require(listing.unstakedDeposit - _amount >= minDeposit);

        listing.unstakedDeposit -= _amount;
        require(token.transfer(msg.sender, _amount));

        emit _Withdrawal(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to remove the listingHash from the whitelist
                        Returns all tokens to the owner of the listingHash
    @param _listingHash A listingHash msg.sender is the owner of.
    */
    function exit(bytes32 _listingHash) external {
        Listing storage listing = listings[_listingHash];

        require(msg.sender == listing.owner);
        require(isWhitelisted(_listingHash));

        // Cannot exit during ongoing challenge
        require(listing.challengeID == 0 || challenges[listing.challengeID].resolved);

        // Remove listingHash & return tokens
        resetListing(_listingHash);
        emit _ListingWithdrawn(_listingHash);
    }

    // -----------------------
    // TOKEN HOLDER INTERFACE:
    // -----------------------

    /**
    @dev                Starts a poll for a listingHash which is either in the apply stage or
                        already in the whitelist. Tokens are taken from the challenger and the
                        applicant's deposits are locked.
    @param _listingHash The listingHash being challenged, whether listed or in application
    @param _data        Extra data relevant to the challenge. Think IPFS hashes.
    */
    function challenge(bytes32 _listingHash, string _data) external returns (uint challengeID) {
        Listing storage listing = listings[_listingHash];

        // Listing must be in apply stage or already on the whitelist
        require(appWasMade(_listingHash) || listing.whitelisted);
        // Prevent multiple challenges
        require(listing.challengeID == 0 || challenges[listing.challengeID].resolved);

        if (listing.unstakedDeposit < minDeposit) {
            // Not enough tokens, listingHash auto-delisted
            resetListing(_listingHash);
            emit _TouchAndRemoved(_listingHash);
            return 0;
        }

        // Starts poll
        uint pollID = voting.startPoll(
            voteQuorum,
            commitStageLen,
            revealStageLen
        );

        uint oneHundred = 100; // Kludge that we need to use SafeMath
        challenges[pollID] = Challenge({
            challenger: msg.sender,
            rewardPool: ((oneHundred.sub(dispensationPct)).mul(minDeposit)).div(100),
            stake: minDeposit,
            resolved: false,
            totalTokens: 0
        });

        // Updates listingHash to store most recent challenge
        listing.challengeID = pollID;

        // Locks tokens for listingHash during challenge
        listing.unstakedDeposit -= minDeposit;

        // Takes tokens from challenger
        require(token.transferFrom(msg.sender, this, minDeposit));
		uint256 commitEndDate;
		uint256 revealEndDate;
		(commitEndDate, revealEndDate, )  = voting.pollMap(pollID);

        emit _Challenge(_listingHash, pollID, _data, commitEndDate, revealEndDate, msg.sender);
        return pollID;
    }

    /**
    @dev                Updates a listingHash's status from 'application' to 'listing' or resolves
                        a challenge if one exists.
    @param _listingHash The listingHash whose status is being updated
    */
    function updateStatus(bytes32 _listingHash) public {
        if (canBeWhitelisted(_listingHash)) {
            whitelistApplication(_listingHash);
        } else if (challengeCanBeResolved(_listingHash)) {
            resolveChallenge(_listingHash);
        } else {
            revert();
        }
    }

    /**
    @dev                  Updates an array of listingHashes' status from 'application' to 'listing' or resolves
                          a challenge if one exists.
    @param _listingHashes The listingHashes whose status are being updated
    */
    function updateStatuses(bytes32[] _listingHashes) public {
        // loop through arrays, revealing each individual vote values
        for (uint i = 0; i < _listingHashes.length; i++) {
            updateStatus(_listingHashes[i]);
        }
    }

    // ----------------
    // TOKEN FUNCTIONS:
    // ----------------

    /**
    @dev                Called by a voter to claim their reward for each completed vote. Someone
                        must call updateStatus() before this can be called.
    @param _challengeID The PLCR pollID of the challenge a reward is being claimed for
    @param _salt        The salt of a voter's commit hash in the given poll
    */
    function claimReward(uint _challengeID, uint _salt) public {
        // Ensures the voter has not already claimed tokens and challenge results have been processed
        require(challenges[_challengeID].tokenClaims[msg.sender] == false);
        require(challenges[_challengeID].resolved == true);

        uint voterTokens = voting.getNumPassingTokens(msg.sender, _challengeID, _salt);
        uint reward = voterReward(msg.sender, _challengeID, _salt);

        // Subtracts the voter's information to preserve the participation ratios
        // of other voters compared to the remaining pool of rewards
        challenges[_challengeID].totalTokens -= voterTokens;
        challenges[_challengeID].rewardPool -= reward;

        // Ensures a voter cannot claim tokens again
        challenges[_challengeID].tokenClaims[msg.sender] = true;

        require(token.transfer(msg.sender, reward));

        emit _RewardClaimed(_challengeID, reward, msg.sender);
    }

    /**
    @dev                 Called by a voter to claim their rewards for each completed vote. Someone
                         must call updateStatus() before this can be called.
    @param _challengeIDs The PLCR pollIDs of the challenges rewards are being claimed for
    @param _salts        The salts of a voter's commit hashes in the given polls
    */
    function claimRewards(uint[] _challengeIDs, uint[] _salts) public {
        // make sure the array lengths are the same
        require(_challengeIDs.length == _salts.length);

        // loop through arrays, claiming each individual vote reward
        for (uint i = 0; i < _challengeIDs.length; i++) {
            claimReward(_challengeIDs[i], _salts[i]);
        }
    }

    // --------
    // GETTERS:
    // --------

    /**
    @dev                Calculates the provided voter's token reward for the given poll.
    @param _voter       The address of the voter whose reward balance is to be returned
    @param _challengeID The pollID of the challenge a reward balance is being queried for
    @param _salt        The salt of the voter's commit hash in the given poll
    @return             The uint indicating the voter's reward
    */
    function voterReward(address _voter, uint _challengeID, uint _salt)
    public view returns (uint) {
        uint totalTokens = challenges[_challengeID].totalTokens;
        uint rewardPool = challenges[_challengeID].rewardPool;
        uint voterTokens = voting.getNumPassingTokens(_voter, _challengeID, _salt);
        return (voterTokens * rewardPool) / totalTokens;
    }

    /**
    @dev                Determines whether the given listingHash be whitelisted.
    @param _listingHash The listingHash whose status is to be examined
    */
    function canBeWhitelisted(bytes32 _listingHash) view public returns (bool) {
        uint challengeID = listings[_listingHash].challengeID;

        // Ensures that the application was made,
        // the application period has ended,
        // the listingHash can be whitelisted,
        // and either: the challengeID == 0, or the challenge has been resolved.
        if (
            appWasMade(_listingHash) &&
            listings[_listingHash].applicationExpiry < now &&
            !isWhitelisted(_listingHash) &&
            (challengeID == 0 || challenges[challengeID].resolved == true)
        ) { return true; }

        return false;
    }

    /**
    @dev                Returns true if the provided listingHash is whitelisted
    @param _listingHash The listingHash whose status is to be examined
    */
    function isWhitelisted(bytes32 _listingHash) view public returns (bool whitelisted) {
        return listings[_listingHash].whitelisted;
    }

    /**
    @dev                Returns true if apply was called for this listingHash
    @param _listingHash The listingHash whose status is to be examined
    */
    function appWasMade(bytes32 _listingHash) view public returns (bool exists) {
        return listings[_listingHash].applicationExpiry > 0;
    }

    /**
    @dev                Returns true if the application/listingHash has an unresolved challenge
    @param _listingHash The listingHash whose status is to be examined
    */
    function challengeExists(bytes32 _listingHash) view public returns (bool) {
        uint challengeID = listings[_listingHash].challengeID;

        return (listings[_listingHash].challengeID > 0 && !challenges[challengeID].resolved);
    }

    /**
    @dev                Determines whether voting has concluded in a challenge for a given
                        listingHash. Throws if no challenge exists.
    @param _listingHash A listingHash with an unresolved challenge
    */
    function challengeCanBeResolved(bytes32 _listingHash) view public returns (bool) {
        uint challengeID = listings[_listingHash].challengeID;

        require(challengeExists(_listingHash));

        return voting.pollEnded(challengeID);
    }

    /**
    @dev                Determines the number of tokens awarded to the winning party in a challenge.
    @param _challengeID The challengeID to determine a reward for
    */
    function determineReward(uint _challengeID) public view returns (uint) {
        require(!challenges[_challengeID].resolved && voting.pollEnded(_challengeID));

        // Edge case, nobody voted, give all tokens to the challenger.
        if (voting.getTotalNumberOfTokensForWinningOption(_challengeID) == 0) {
            return 2 * challenges[_challengeID].stake;
        }

        return (2 * challenges[_challengeID].stake) - challenges[_challengeID].rewardPool;
    }

    /**
    @dev                Getter for Challenge tokenClaims mappings
    @param _challengeID The challengeID to query
    @param _voter       The voter whose claim status to query for the provided challengeID
    */
    function tokenClaims(uint _challengeID, address _voter) public view returns (bool) {
        return challenges[_challengeID].tokenClaims[_voter];
    }

    // ----------------
    // PRIVATE FUNCTIONS:
    // ----------------

    /**
    @dev                Determines the winner in a challenge. Rewards the winner tokens and
                        either whitelists or de-whitelists the listingHash.
    @param _listingHash A listingHash with a challenge that is to be resolved
    */
    function resolveChallenge(bytes32 _listingHash) private {
        uint challengeID = listings[_listingHash].challengeID;

        // Calculates the winner's reward,
        // which is: (winner's full stake) + (dispensationPct * loser's stake)
        uint reward = determineReward(challengeID);

        // Sets flag on challenge being processed
        challenges[challengeID].resolved = true;

        // Stores the total tokens used for voting by the winning side for reward purposes
        challenges[challengeID].totalTokens =
            voting.getTotalNumberOfTokensForWinningOption(challengeID);

        // Case: challenge failed
        if (voting.isPassed(challengeID)) {
            whitelistApplication(_listingHash);
            // Unlock stake so that it can be retrieved by the applicant
            listings[_listingHash].unstakedDeposit += reward;

            emit _ChallengeFailed(_listingHash, challengeID, challenges[challengeID].rewardPool, challenges[challengeID].totalTokens);
        }
        // Case: challenge succeeded or nobody voted
        else {
            resetListing(_listingHash);
            // Transfer the reward to the challenger
            require(token.transfer(challenges[challengeID].challenger, reward));

            emit _ChallengeSucceeded(_listingHash, challengeID, challenges[challengeID].rewardPool, challenges[challengeID].totalTokens);
        }
    }

    /**
    @dev                Called by updateStatus() if the applicationExpiry date passed without a
                        challenge being made. Called by resolveChallenge() if an
                        application/listing beat a challenge.
    @param _listingHash The listingHash of an application/listingHash to be whitelisted
    */
    function whitelistApplication(bytes32 _listingHash) private {
        if (!listings[_listingHash].whitelisted) { emit _ApplicationWhitelisted(_listingHash); }
        listings[_listingHash].whitelisted = true;
    }

    /**
    @dev                Deletes a listingHash from the whitelist and transfers tokens back to owner
    @param _listingHash The listing hash to delete
    */
    function resetListing(bytes32 _listingHash) private {
        Listing storage listing = listings[_listingHash];

        // Emit events before deleting listing to check whether is whitelisted
        if (listing.whitelisted) {
            emit _ListingRemoved(_listingHash);
        } else {
            emit _ApplicationRemoved(_listingHash);
        }

        // Deleting listing to prevent reentry
        address owner = listing.owner;
        uint unstakedDeposit = listing.unstakedDeposit;
        delete listings[_listingHash];
        
        // Transfers any remaining balance back to the owner
        if (unstakedDeposit > 0){
            require(token.transfer(owner, unstakedDeposit));
        }
    }
}












/**
@title Partial-Lock-Commit-Reveal Voting scheme with ERC20 tokens
@author Team: Aspyn Palatnick, Cem Ozer, Yorke Rhodes
*/
contract PLCRVoting {

    // ============
    // EVENTS:
    // ============

    event _VoteCommitted(uint indexed pollID, uint numTokens, address indexed voter);
    event _VoteRevealed(uint indexed pollID, uint numTokens, uint votesFor, uint votesAgainst, uint indexed choice, address indexed voter);
    event _PollCreated(uint voteQuorum, uint commitEndDate, uint revealEndDate, uint indexed pollID, address indexed creator);
    event _VotingRightsGranted(uint numTokens, address indexed voter);
    event _VotingRightsWithdrawn(uint numTokens, address indexed voter);
    event _TokensRescued(uint indexed pollID, address indexed voter);

    // ============
    // DATA STRUCTURES:
    // ============

    using AttributeStore for AttributeStore.Data;
    using DLL for DLL.Data;
    using SafeMath for uint;

    struct Poll {
		// WARNING - THIS STRUCT MUST BE EXACTLY COPIED TO CHILD CONTRACTS;
        uint commitEndDate;     /// expiration date of commit period for poll
        uint revealEndDate;     /// expiration date of reveal period for poll
        uint voteQuorum;	    /// number of votes required for a proposal to pass
        uint votesFor;		    /// tally of votes supporting proposal
        uint votesAgainst;      /// tally of votes countering proposal
        mapping(address => bool) didCommit;  /// indicates whether an address committed a vote for this poll
        mapping(address => bool) didReveal;   /// indicates whether an address revealed a vote for this poll
    }

    // ============
    // STATE VARIABLES:
    // ============

    uint constant public INITIAL_POLL_NONCE = 0;
    uint public pollNonce;

    mapping(uint => Poll) public pollMap; // maps pollID to Poll struct
    mapping(address => uint) public voteTokenBalance; // maps user's address to voteToken balance

    mapping(address => DLL.Data) dllMap;
    AttributeStore.Data store;

    ERC20 public token;

    /**
    @dev Initializer. Can only be called once.
    @param _token The address where the ERC20 token contract is deployed
    */
    function init(address _token) public {
        require(_token != 0 && address(token) == 0);

        token = ERC20(_token);
        pollNonce = INITIAL_POLL_NONCE;
    }

    // ================
    // TOKEN INTERFACE:
    // ================

    /**
    @notice Loads _numTokens ERC20 tokens into the voting contract for one-to-one voting rights
    @dev Assumes that msg.sender has approved voting contract to spend on their behalf
    @param _numTokens The number of votingTokens desired in exchange for ERC20 tokens
    */
    function requestVotingRights(uint _numTokens) public {
        require(token.balanceOf(msg.sender) >= _numTokens);
        voteTokenBalance[msg.sender] += _numTokens;
        require(token.transferFrom(msg.sender, this, _numTokens));
        emit _VotingRightsGranted(_numTokens, msg.sender);
    }

    /**
    @notice Withdraw _numTokens ERC20 tokens from the voting contract, revoking these voting rights
    @param _numTokens The number of ERC20 tokens desired in exchange for voting rights
    */
    function withdrawVotingRights(uint _numTokens) external {
        uint availableTokens = voteTokenBalance[msg.sender].sub(getLockedTokens(msg.sender));
        require(availableTokens >= _numTokens);
        voteTokenBalance[msg.sender] -= _numTokens;
        require(token.transfer(msg.sender, _numTokens));
        emit _VotingRightsWithdrawn(_numTokens, msg.sender);
    }

    /**
    @dev Unlocks tokens locked in unrevealed vote where poll has ended
    @param _pollID Integer identifier associated with the target poll
    */
    function rescueTokens(uint _pollID) public {
        require(isExpired(pollMap[_pollID].revealEndDate));
        require(dllMap[msg.sender].contains(_pollID));

        dllMap[msg.sender].remove(_pollID);
        emit _TokensRescued(_pollID, msg.sender);
    }

    /**
    @dev Unlocks tokens locked in unrevealed votes where polls have ended
    @param _pollIDs Array of integer identifiers associated with the target polls
    */
    function rescueTokensInMultiplePolls(uint[] _pollIDs) public {
        // loop through arrays, rescuing tokens from all
        for (uint i = 0; i < _pollIDs.length; i++) {
            rescueTokens(_pollIDs[i]);
        }
    }

    // =================
    // VOTING INTERFACE:
    // =================

    /**
    @notice Commits vote using hash of choice and secret salt to conceal vote until reveal
    @param _pollID Integer identifier associated with target poll
    @param _secretHash Commit keccak256 hash of voter's choice and salt (tightly packed in this order)
    @param _numTokens The number of tokens to be committed towards the target poll
    @param _prevPollID The ID of the poll that the user has voted the maximum number of tokens in which is still less than or equal to numTokens
    */
    function commitVote(uint _pollID, bytes32 _secretHash, uint _numTokens, uint _prevPollID) public {
        require(commitPeriodActive(_pollID));

        // if msg.sender doesn't have enough voting rights,
        // request for enough voting rights
        if (voteTokenBalance[msg.sender] < _numTokens) {
            uint remainder = _numTokens.sub(voteTokenBalance[msg.sender]);
            requestVotingRights(remainder);
        }

        // make sure msg.sender has enough voting rights
        require(voteTokenBalance[msg.sender] >= _numTokens);
        // prevent user from committing to zero node placeholder
        require(_pollID != 0);
        // prevent user from committing a secretHash of 0
        require(_secretHash != 0);

        // Check if _prevPollID exists in the user's DLL or if _prevPollID is 0
        require(_prevPollID == 0 || dllMap[msg.sender].contains(_prevPollID));

        uint nextPollID = dllMap[msg.sender].getNext(_prevPollID);

        // edge case: in-place update
        if (nextPollID == _pollID) {
            nextPollID = dllMap[msg.sender].getNext(_pollID);
        }

        require(validPosition(_prevPollID, nextPollID, msg.sender, _numTokens));
        dllMap[msg.sender].insert(_prevPollID, _pollID, nextPollID);

        bytes32 UUID = attrUUID(msg.sender, _pollID);

        store.setAttribute(UUID, "numTokens", _numTokens);
        store.setAttribute(UUID, "commitHash", uint(_secretHash));

        pollMap[_pollID].didCommit[msg.sender] = true;
        emit _VoteCommitted(_pollID, _numTokens, msg.sender);
    }

    /**
    @notice                 Commits votes using hashes of choices and secret salts to conceal votes until reveal
    @param _pollIDs         Array of integer identifiers associated with target polls
    @param _secretHashes    Array of commit keccak256 hashes of voter's choices and salts (tightly packed in this order)
    @param _numsTokens      Array of numbers of tokens to be committed towards the target polls
    @param _prevPollIDs     Array of IDs of the polls that the user has voted the maximum number of tokens in which is still less than or equal to numTokens
    */
    function commitVotes(uint[] _pollIDs, bytes32[] _secretHashes, uint[] _numsTokens, uint[] _prevPollIDs) external {
        // make sure the array lengths are all the same
        require(_pollIDs.length == _secretHashes.length);
        require(_pollIDs.length == _numsTokens.length);
        require(_pollIDs.length == _prevPollIDs.length);

        // loop through arrays, committing each individual vote values
        for (uint i = 0; i < _pollIDs.length; i++) {
            commitVote(_pollIDs[i], _secretHashes[i], _numsTokens[i], _prevPollIDs[i]);
        }
    }

    /**
    @dev Compares previous and next poll's committed tokens for sorting purposes
    @param _prevID Integer identifier associated with previous poll in sorted order
    @param _nextID Integer identifier associated with next poll in sorted order
    @param _voter Address of user to check DLL position for
    @param _numTokens The number of tokens to be committed towards the poll (used for sorting)
    @return valid Boolean indication of if the specified position maintains the sort
    */
    function validPosition(uint _prevID, uint _nextID, address _voter, uint _numTokens) public constant returns (bool valid) {
        bool prevValid = (_numTokens >= getNumTokens(_voter, _prevID));
        // if next is zero node, _numTokens does not need to be greater
        bool nextValid = (_numTokens <= getNumTokens(_voter, _nextID) || _nextID == 0);
        return prevValid && nextValid;
    }

    /**
    @notice Reveals vote with choice and secret salt used in generating commitHash to attribute committed tokens
    @param _pollID Integer identifier associated with target poll
    @param _voteOption Vote choice used to generate commitHash for associated poll
    @param _salt Secret number used to generate commitHash for associated poll
    */
    function revealVote(uint _pollID, uint _voteOption, uint _salt) public {
        // Make sure the reveal period is active
        require(revealPeriodActive(_pollID));
        require(pollMap[_pollID].didCommit[msg.sender]);                         // make sure user has committed a vote for this poll
        require(!pollMap[_pollID].didReveal[msg.sender]);                        // prevent user from revealing multiple times
        require(keccak256(_voteOption, _salt) == getCommitHash(msg.sender, _pollID)); // compare resultant hash from inputs to original commitHash

        uint numTokens = getNumTokens(msg.sender, _pollID);

        if (_voteOption == 1) {// apply numTokens to appropriate poll choice
            pollMap[_pollID].votesFor += numTokens;
        } else {
            pollMap[_pollID].votesAgainst += numTokens;
        }

        dllMap[msg.sender].remove(_pollID); // remove the node referring to this vote upon reveal
        pollMap[_pollID].didReveal[msg.sender] = true;

        emit _VoteRevealed(_pollID, numTokens, pollMap[_pollID].votesFor, pollMap[_pollID].votesAgainst, _voteOption, msg.sender);
    }

    /**
    @notice             Reveals multiple votes with choices and secret salts used in generating commitHashes to attribute committed tokens
    @param _pollIDs     Array of integer identifiers associated with target polls
    @param _voteOptions Array of vote choices used to generate commitHashes for associated polls
    @param _salts       Array of secret numbers used to generate commitHashes for associated polls
    */
    function revealVotes(uint[] _pollIDs, uint[] _voteOptions, uint[] _salts) external {
        // make sure the array lengths are all the same
        require(_pollIDs.length == _voteOptions.length);
        require(_pollIDs.length == _salts.length);

        // loop through arrays, revealing each individual vote values
        for (uint i = 0; i < _pollIDs.length; i++) {
            revealVote(_pollIDs[i], _voteOptions[i], _salts[i]);
        }
    }

    /**
    @param _pollID Integer identifier associated with target poll
    @param _salt Arbitrarily chosen integer used to generate secretHash
    @return correctVotes Number of tokens voted for winning option
    */
    function getNumPassingTokens(address _voter, uint _pollID, uint _salt) public constant returns (uint correctVotes) {
        require(pollEnded(_pollID));
        require(pollMap[_pollID].didReveal[_voter]);

        uint winningChoice = isPassed(_pollID) ? 1 : 0;
        bytes32 winnerHash = keccak256(winningChoice, _salt);
        bytes32 commitHash = getCommitHash(_voter, _pollID);

        require(winnerHash == commitHash);

        return getNumTokens(_voter, _pollID);
    }

    // ==================
    // POLLING INTERFACE:
    // ==================

    /**
    @dev Initiates a poll with canonical configured parameters at pollID emitted by PollCreated event
    @param _voteQuorum Type of majority (out of 100) that is necessary for poll to be successful
    @param _commitDuration Length of desired commit period in seconds
    @param _revealDuration Length of desired reveal period in seconds
    */
    function startPoll(uint _voteQuorum, uint _commitDuration, uint _revealDuration) public returns (uint pollID) {
        pollNonce = pollNonce + 1;

        uint commitEndDate = block.timestamp.add(_commitDuration);
        uint revealEndDate = commitEndDate.add(_revealDuration);

        pollMap[pollNonce] = Poll({
            voteQuorum: _voteQuorum,
            commitEndDate: commitEndDate,
            revealEndDate: revealEndDate,
            votesFor: 0,
            votesAgainst: 0
        });

        emit _PollCreated(_voteQuorum, commitEndDate, revealEndDate, pollNonce, msg.sender);
        return pollNonce;
    }

    /**
    @notice Determines if proposal has passed
    @dev Check if votesFor out of totalVotes exceeds votesQuorum (requires pollEnded)
    @param _pollID Integer identifier associated with target poll
    */
    function isPassed(uint _pollID) constant public returns (bool passed) {
        require(pollEnded(_pollID));

        Poll memory poll = pollMap[_pollID];
        return (100 * poll.votesFor) > (poll.voteQuorum * (poll.votesFor + poll.votesAgainst));
    }

    // ----------------
    // POLLING HELPERS:
    // ----------------

    /**
    @dev Gets the total winning votes for reward distribution purposes
    @param _pollID Integer identifier associated with target poll
    @return Total number of votes committed to the winning option for specified poll
    */
    function getTotalNumberOfTokensForWinningOption(uint _pollID) constant public returns (uint numTokens) {
        require(pollEnded(_pollID));

        if (isPassed(_pollID))
            return pollMap[_pollID].votesFor;
        else
            return pollMap[_pollID].votesAgainst;
    }

    /**
    @notice Determines if poll is over
    @dev Checks isExpired for specified poll's revealEndDate
    @return Boolean indication of whether polling period is over
    */
    function pollEnded(uint _pollID) constant public returns (bool ended) {
        require(pollExists(_pollID));

        return isExpired(pollMap[_pollID].revealEndDate);
    }

    /**
    @notice Checks if the commit period is still active for the specified poll
    @dev Checks isExpired for the specified poll's commitEndDate
    @param _pollID Integer identifier associated with target poll
    @return Boolean indication of isCommitPeriodActive for target poll
    */
    function commitPeriodActive(uint _pollID) constant public returns (bool active) {
        require(pollExists(_pollID));

        return !isExpired(pollMap[_pollID].commitEndDate);
    }

    /**
    @notice Checks if the reveal period is still active for the specified poll
    @dev Checks isExpired for the specified poll's revealEndDate
    @param _pollID Integer identifier associated with target poll
    */
    function revealPeriodActive(uint _pollID) constant public returns (bool active) {
        require(pollExists(_pollID));

        return !isExpired(pollMap[_pollID].revealEndDate) && !commitPeriodActive(_pollID);
    }

    /**
    @dev Checks if user has committed for specified poll
    @param _voter Address of user to check against
    @param _pollID Integer identifier associated with target poll
    @return Boolean indication of whether user has committed
    */
    function didCommit(address _voter, uint _pollID) constant public returns (bool committed) {
        require(pollExists(_pollID));

        return pollMap[_pollID].didCommit[_voter];
    }

    /**
    @dev Checks if user has revealed for specified poll
    @param _voter Address of user to check against
    @param _pollID Integer identifier associated with target poll
    @return Boolean indication of whether user has revealed
    */
    function didReveal(address _voter, uint _pollID) constant public returns (bool revealed) {
        require(pollExists(_pollID));

        return pollMap[_pollID].didReveal[_voter];
    }

    /**
    @dev Checks if a poll exists
    @param _pollID The pollID whose existance is to be evaluated.
    @return Boolean Indicates whether a poll exists for the provided pollID
    */
    function pollExists(uint _pollID) constant public returns (bool exists) {
        return (_pollID != 0 && _pollID <= pollNonce);
    }

    // ---------------------------
    // DOUBLE-LINKED-LIST HELPERS:
    // ---------------------------

    /**
    @dev Gets the bytes32 commitHash property of target poll
    @param _voter Address of user to check against
    @param _pollID Integer identifier associated with target poll
    @return Bytes32 hash property attached to target poll
    */
    function getCommitHash(address _voter, uint _pollID) constant public returns (bytes32 commitHash) {
        return bytes32(store.getAttribute(attrUUID(_voter, _pollID), "commitHash"));
    }

    /**
    @dev Wrapper for getAttribute with attrName="numTokens"
    @param _voter Address of user to check against
    @param _pollID Integer identifier associated with target poll
    @return Number of tokens committed to poll in sorted poll-linked-list
    */
    function getNumTokens(address _voter, uint _pollID) constant public returns (uint numTokens) {
        return store.getAttribute(attrUUID(_voter, _pollID), "numTokens");
    }

    /**
    @dev Gets top element of sorted poll-linked-list
    @param _voter Address of user to check against
    @return Integer identifier to poll with maximum number of tokens committed to it
    */
    function getLastNode(address _voter) constant public returns (uint pollID) {
        return dllMap[_voter].getPrev(0);
    }

    /**
    @dev Gets the numTokens property of getLastNode
    @param _voter Address of user to check against
    @return Maximum number of tokens committed in poll specified
    */
    function getLockedTokens(address _voter) constant public returns (uint numTokens) {
        return getNumTokens(_voter, getLastNode(_voter));
    }

    /*
    @dev Takes the last node in the user's DLL and iterates backwards through the list searching
    for a node with a value less than or equal to the provided _numTokens value. When such a node
    is found, if the provided _pollID matches the found nodeID, this operation is an in-place
    update. In that case, return the previous node of the node being updated. Otherwise return the
    first node that was found with a value less than or equal to the provided _numTokens.
    @param _voter The voter whose DLL will be searched
    @param _numTokens The value for the numTokens attribute in the node to be inserted
    @return the node which the propoded node should be inserted after
    */
    function getInsertPointForNumTokens(address _voter, uint _numTokens, uint _pollID)
    constant public returns (uint prevNode) {
      // Get the last node in the list and the number of tokens in that node
      uint nodeID = getLastNode(_voter);
      uint tokensInNode = getNumTokens(_voter, nodeID);

      // Iterate backwards through the list until reaching the root node
      while(nodeID != 0) {
        // Get the number of tokens in the current node
        tokensInNode = getNumTokens(_voter, nodeID);
        if(tokensInNode <= _numTokens) { // We found the insert point!
          if(nodeID == _pollID) {
            // This is an in-place update. Return the prev node of the node being updated
            nodeID = dllMap[_voter].getPrev(nodeID);
          }
          // Return the insert point
          return nodeID; 
        }
        // We did not find the insert point. Continue iterating backwards through the list
        nodeID = dllMap[_voter].getPrev(nodeID);
      }

      // The list is empty, or a smaller value than anything else in the list is being inserted
      return nodeID;
    }

    // ----------------
    // GENERAL HELPERS:
    // ----------------

    /**
    @dev Checks if an expiration date has been reached
    @param _terminationDate Integer timestamp of date to compare current timestamp with
    @return expired Boolean indication of whether the terminationDate has passed
    */
    function isExpired(uint _terminationDate) constant public returns (bool expired) {
        return (block.timestamp > _terminationDate);
    }

    /**
    @dev Generates an identifier which associates a user and a poll together
    @param _pollID Integer identifier associated with target poll
    @return UUID Hash which is deterministic from _user and _pollID
    */
    function attrUUID(address _user, uint _pollID) public pure returns (bytes32 UUID) {
        return keccak256(_user, _pollID);
    }
}





