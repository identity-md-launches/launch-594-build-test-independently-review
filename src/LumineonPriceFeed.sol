// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleAttestation} from "./OracleAttestation.sol";

/// @title LumineonPriceFeed
/// @notice On-chain USD-cent price of one graded Pokémon card, updated only by IdentityMD (IMD)
///         oracle attestations: Lumineon V, Crown Zenith: Galarian Gallery GG39/GG70, PSA 10,
///         headline PriceCharting "PSA 10" price-guide estimate.
/// @dev Testnet prototype for Ethereum Sepolia. Non-upgradeable, holds no funds, has no manual
///      price setter. Trust model:
///        - `attester`  (immutable): the IMD signer. Only its EIP-712 signatures over this
///                       contract's own domain (this chain id, this address) are accepted.
///        - `owner`     (two-step transferable): approves the `questionHash` of each oracle request
///                       whose answer may enter the feed. It cannot set a price, cannot forge an
///                       attestation, cannot revoke an approval and cannot change the attester.
///        - anyone:      may relay a valid attestation (`submitAttestation`) and read the feed.
///
///      Why an approver exists: IMD hashes the whole pinned request, so every new request (even
///      with identical text) carries a new `questionHash`. The contract cannot recompute it from the
///      card question alone, and without a binding the first relayer of any attestation signed for
///      this consumer could choose the question. The owner reads the hash from IMD's public API the
///      moment the request is created, before any answer exists, and approves it. The canonical
///      question text hash (`QUESTION_TEXT_HASH`) is exposed so an approver can check the request's
///      text byte-for-byte before approving.
contract LumineonPriceFeed {
    // ------------------------------------------------------------------ card and price definition

    string public constant CARD_NAME = "Lumineon V";
    string public constant SET_NAME = "Crown Zenith: Galarian Gallery";
    string public constant CARD_NUMBER = "GG39/GG70";
    string public constant LANGUAGE = "English";
    string public constant GAME = "Pokemon TCG";
    string public constant GRADING_COMPANY = "PSA";
    uint8 public constant GRADE = 10;
    string public constant CURRENCY = "USD";
    string public constant DENOMINATION = "cents (1 USD = 100)";
    string public constant PRICE_SOURCE_URL = "https://www.pricecharting.com/game/pokemon-crown-zenith/lumineon-v-gg39";
    string public constant PRICE_DEFINITION =
        "Headline PriceCharting price-guide estimate labelled 'PSA 10'; a published benchmark observation, not a sale, asking price, guaranteed resale value or cross-source average; excludes shipping, taxes and fees.";

    /// @notice keccak256 of the exact UTF-8 question text in docs/oracle-request-template.json.
    /// @dev Metadata for approvers and relayers. It is NOT the signed `questionHash`: IMD's hash covers
    ///      the whole pinned request (see contract notes).
    bytes32 public constant QUESTION_TEXT_HASH = 0x3fbd772da2fd23d430b982d57a8e50a2e9a72e51764c7029881b4f30cabcce77;

    // ------------------------------------------------------------------ acceptance policy

    /// @notice Minimum panel size the signed attestation must carry.
    uint16 public constant MIN_PANEL_SIZE = 20;
    /// @notice Minimum quorum the signed attestation must carry.
    uint16 public constant MIN_QUORUM = 14;
    /// @notice Maximum accepted age of an attestation, measured from its signed `issuedAt`.
    uint64 public constant MAX_AGE = 24 hours;
    /// @notice The `chainId` field of the signed message: the chain the request's window was pinned
    ///         on. The request template pins Ethereum mainnet (1) because the price is web evidence
    ///         and the window only timestamps it. The consumer chain is enforced by the EIP-712 domain.
    uint256 public constant QUESTION_CHAIN_ID = 1;
    /// @notice IMD answerType for uint256.
    uint8 public constant ANSWER_TYPE = OracleAttestation.ANSWER_TYPE_UINT256;

    // ------------------------------------------------------------------ immutable configuration

    /// @notice The IMD attester whose signatures are trusted.
    address public immutable attester;
    /// @notice EIP-712 domain separator: name "IdentityMD Oracle", version "2", this chain, this contract.
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ------------------------------------------------------------------ storage

    struct Observation {
        uint256 priceCents;
        bytes32 requestId;
        bytes32 questionHash;
        bytes32 panelJobId;
        uint64 issuedAt;
        uint64 expiresAt;
        uint64 receivedAt;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
    }

    address public owner;
    address public pendingOwner;
    Observation private _last;
    bool private _hasObservation;
    mapping(bytes32 questionHash => bool approved) public approvedQuestions;
    mapping(bytes32 requestId => bool used) public usedRequests;

    // ------------------------------------------------------------------ events

    event PriceUpdated(
        bytes32 indexed requestId,
        bytes32 indexed questionHash,
        uint256 priceCents,
        uint64 issuedAt,
        uint64 expiresAt,
        uint64 receivedAt,
        uint16 panelSize,
        uint16 quorum,
        uint16 agreed,
        address relayer
    );
    event QuestionApproved(bytes32 indexed questionHash, address indexed approver);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------ errors

    error InvalidConfiguration();
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error QuestionAlreadyApproved();
    error QuestionNotApproved(bytes32 questionHash);
    error WrongQuestionChain(uint256 chainId);
    error WrongAnswerType(uint8 answerType);
    error MalformedAnswer();
    error AnswerFigureMismatch(uint256 decoded, uint256 figure);
    error ZeroPrice();
    error InsufficientPanel(uint16 panelSize);
    error InsufficientQuorum(uint16 quorum);
    error InconsistentCounts(uint16 panelSize, uint16 quorum, uint16 agreed);
    error InsufficientAgreement(uint16 agreed, uint16 quorum);
    error InvalidValidity(uint64 issuedAt, uint64 expiresAt);
    error IssuedInFuture(uint64 issuedAt, uint256 blockTime);
    error AttestationExpired(uint64 expiresAt, uint256 blockTime);
    error AttestationTooOld(uint64 issuedAt, uint256 blockTime);
    error RequestAlreadyUsed(bytes32 requestId);
    error NotNewerThanStored(uint64 issuedAt, uint64 storedIssuedAt);
    error InvalidSignature();
    error NoObservation();
    error StalePrice(uint64 issuedAt, uint64 expiresAt, uint256 blockTime);

    // ------------------------------------------------------------------ construction

    /// @param owner_ Question approver. Supplied by the launch manifest as `$owner` (the requester's
    ///        configured wallet), never the deploying factory's `msg.sender`.
    /// @param attester_ IMD's attestation signer, pinned from the network configuration.
    constructor(address owner_, address attester_) {
        if (owner_ == address(0) || attester_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
        attester = attester_;
        DOMAIN_SEPARATOR = OracleAttestation.domainSeparator(block.chainid, address(this));
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------ owner: question binding

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Approve the `questionHash` of one IMD oracle request so its attestation may update
    ///         the feed. Read the hash from `GET /oracle/requests/:id` after paying for the request.
    /// @dev Approvals are permanent and cannot be revoked; each hash identifies one pinned request,
    ///      so a mistaken approval admits at most that request's single signed answer.
    function approveQuestion(bytes32 questionHash) external onlyOwner {
        if (questionHash == bytes32(0)) revert InvalidConfiguration();
        if (approvedQuestions[questionHash]) revert QuestionAlreadyApproved();
        approvedQuestions[questionHash] = true;
        emit QuestionApproved(questionHash, msg.sender);
    }

    /// @notice Begin a two-step ownership transfer. The new owner must call `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    // ------------------------------------------------------------------ relay

    /// @notice Relay an IMD attestation. Anyone may call; only a valid signature from `attester`
    ///         over this contract's domain, answering an approved question, can change the price.
    /// @param a   The `message` of `GET /oracle/requests/:id/attestation`, field for field.
    /// @param sig The 65-byte `signature` from the same response.
    function submitAttestation(OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        // 1. Question binding and chain context.
        if (!approvedQuestions[a.questionHash]) revert QuestionNotApproved(a.questionHash);
        if (a.chainId != QUESTION_CHAIN_ID) revert WrongQuestionChain(a.chainId);

        // 2. Answer encoding: a positive uint256 whose figure agrees with the encoded answer.
        if (a.answerType != ANSWER_TYPE) revert WrongAnswerType(a.answerType);
        if (a.answer.length != 32) revert MalformedAnswer();
        uint256 decoded = abi.decode(a.answer, (uint256));
        if (decoded != a.figure) revert AnswerFigureMismatch(decoded, a.figure);
        if (decoded == 0) revert ZeroPrice();

        // 3. Panel evidence, as signed.
        if (a.panelSize < MIN_PANEL_SIZE) revert InsufficientPanel(a.panelSize);
        if (a.quorum < MIN_QUORUM) revert InsufficientQuorum(a.quorum);
        if (a.quorum > a.panelSize || a.agreed > a.panelSize) {
            revert InconsistentCounts(a.panelSize, a.quorum, a.agreed);
        }
        if (a.agreed < a.quorum) revert InsufficientAgreement(a.agreed, a.quorum);

        // 4. Time: issued in the past, not expired, not older than MAX_AGE, strictly newer than stored.
        if (a.expiresAt < a.issuedAt) revert InvalidValidity(a.issuedAt, a.expiresAt);
        if (a.issuedAt > block.timestamp) revert IssuedInFuture(a.issuedAt, block.timestamp);
        if (block.timestamp > a.expiresAt) revert AttestationExpired(a.expiresAt, block.timestamp);
        if (block.timestamp - a.issuedAt > MAX_AGE) revert AttestationTooOld(a.issuedAt, block.timestamp);
        if (usedRequests[a.requestId]) revert RequestAlreadyUsed(a.requestId);
        if (_hasObservation && a.issuedAt <= _last.issuedAt) revert NotNewerThanStored(a.issuedAt, _last.issuedAt);

        // 5. Signature over this consumer's domain by the pinned attester.
        address signer = OracleAttestation.recover(OracleAttestation.digest(DOMAIN_SEPARATOR, a), sig);
        if (signer == address(0) || signer != attester) revert InvalidSignature();

        // 6. Effects.
        usedRequests[a.requestId] = true;
        uint64 receivedAt = uint64(block.timestamp);
        _last = Observation({
            priceCents: decoded,
            requestId: a.requestId,
            questionHash: a.questionHash,
            panelJobId: a.panelJobId,
            issuedAt: a.issuedAt,
            expiresAt: a.expiresAt,
            receivedAt: receivedAt,
            panelSize: a.panelSize,
            quorum: a.quorum,
            agreed: a.agreed
        });
        _hasObservation = true;

        emit PriceUpdated(
            a.requestId,
            a.questionHash,
            decoded,
            a.issuedAt,
            a.expiresAt,
            receivedAt,
            a.panelSize,
            a.quorum,
            a.agreed,
            msg.sender
        );
    }

    // ------------------------------------------------------------------ readers

    /// @notice Whether any attestation has ever been accepted.
    function hasObservation() external view returns (bool) {
        return _hasObservation;
    }

    /// @notice The last accepted observation and whether it is still fresh. Reading never changes
    ///         state; an expired observation stays readable as history with `fresh == false`.
    /// @dev Fresh means: an observation exists, it is at most MAX_AGE old by its signed `issuedAt`,
    ///      and its signed `expiresAt` has not passed. `issuedAt` is when IMD signed the panel's
    ///      answer, not the date of any card sale.
    function latestObservation() external view returns (Observation memory observation, bool fresh) {
        return (_last, _isFresh());
    }

    /// @notice True when a fresh observation exists.
    function isFresh() external view returns (bool) {
        return _isFresh();
    }

    /// @notice Strict price reader for consumers: reverts without a fresh observation.
    /// @return cents Price in USD cents.
    /// @return issuedAt When IMD signed the observation.
    function priceCents() external view returns (uint256 cents, uint64 issuedAt) {
        if (!_hasObservation) revert NoObservation();
        if (!_isFresh()) revert StalePrice(_last.issuedAt, _last.expiresAt, block.timestamp);
        return (_last.priceCents, _last.issuedAt);
    }

    /// @notice Seconds since the stored observation was issued, or type(uint256).max when empty.
    function observationAge() external view returns (uint256) {
        if (!_hasObservation) return type(uint256).max;
        return block.timestamp > _last.issuedAt ? block.timestamp - _last.issuedAt : 0;
    }

    /// @notice Human-readable identity of what this feed prices.
    function description() external pure returns (string memory) {
        return string.concat(
            CARD_NAME,
            " | ",
            GAME,
            " | ",
            SET_NAME,
            " ",
            CARD_NUMBER,
            " | ",
            LANGUAGE,
            " | ",
            GRADING_COMPANY,
            " 10 | ",
            CURRENCY,
            " ",
            DENOMINATION,
            " | ",
            PRICE_SOURCE_URL
        );
    }

    function _isFresh() private view returns (bool) {
        if (!_hasObservation) return false;
        if (block.timestamp > _last.expiresAt) return false;
        return block.timestamp - _last.issuedAt <= MAX_AGE;
    }
}
