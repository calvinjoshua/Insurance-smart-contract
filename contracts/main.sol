// SPDX-License-Identifier: MIT
//Update required for gas optimization and migration to the latest Solidity version.pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract Main is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token;

    uint256 public price;

    // Constants for time periods
    uint256 public constant ONE_YEAR = 365 days;  // 31556926 seconds
    uint256 public constant ONE_WEEK = 7 days;    // 604800 seconds
    uint256 public constant ENROLLMENT_FEE = 50;
    uint256 public constant ANNUAL_DUE = 24000;
    uint256 public constant TRANSACTION_FEE = 50;
    uint256 public constant MAX_CLAIM_AMOUNT = 1000000; // Set reasonable max

    struct CustomerDetails {
        uint256 activestart;
        uint256 activeEnd;
        bytes32 name;
        uint256 dob;
        bytes32 policy;
        bool enroll;
        uint256 lockedTokens;
    }

    struct PolicyHealth {
        bytes32 holderName;
        uint256 status;
        uint256 date;
        uint256 claimCount;
        uint256 nextPay;
        uint256 lastPay;
        uint256 paymentCount;
    }

    modifier checkOrg(address org) {
        require(organisation[org] == true, "Invalid organisation");
        _;
    }

    event Enrolled(address indexed user, uint256 date);
    event DuePaid(address indexed user, uint256 tokens, uint256 date);
    event ClaimAdded(address indexed user, string document);
    event Claimed(address indexed user, string document, uint256 tokens);
    event PolicyCancelled(address indexed user, uint256 refundAmount);
    event OrganisationAdded(address indexed org);
    event OrganisationRemoved(address indexed org);

    mapping(address => CustomerDetails) private customersDetails;
    mapping(address => PolicyHealth) public policies;
    mapping(string => address) public claimDataB;
    mapping(address => bool) public organisation;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20Upgradeable _token, uint256 _price)
        public
        initializer
    {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        require(address(_token) != address(0), "Invalid token address");
        token = _token;
        change_price(_price);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function change_price(uint256 _price) public onlyOwner {
        require(_price > 0, "Price must be greater than 0");
        price = _price;
    }

    function enroll(
        bytes32 name,
        uint256 dob
    ) external nonReentrant {
        require(customersDetails[_msgSender()].enroll == false, "Already enrolled!");
        require(dob > 0 && dob < block.timestamp, "Invalid date of birth");
        
        uint256 enrollmentAmount = ENROLLMENT_FEE * (10 ** 18); // Assuming 18 decimals
        require(
            token.balanceOf(_msgSender()) >= enrollmentAmount,
            "Insufficient amount to enroll"
        );

        // Transfer tokens using SafeERC20
        token.safeTransferFrom(_msgSender(), address(this), enrollmentAmount);

        // Check if this is a re-enrollment
        if (customersDetails[_msgSender()].dob != 0) {
            // Existing customer re-enrolling
            customersDetails[_msgSender()].enroll = true;
            customersDetails[_msgSender()].lockedTokens += enrollmentAmount;
            policies[_msgSender()].status = 1;
            policies[_msgSender()].nextPay = block.timestamp + ONE_YEAR;
        } else {
            // New customer
            customersDetails[_msgSender()].enroll = true;
            customersDetails[_msgSender()].name = name;
            customersDetails[_msgSender()].policy = bytes32("health01");
            customersDetails[_msgSender()].dob = dob;
            customersDetails[_msgSender()].activestart = block.timestamp;
            customersDetails[_msgSender()].lockedTokens = enrollmentAmount;

            policies[_msgSender()].holderName = name;
            policies[_msgSender()].status = 1;
            policies[_msgSender()].date = block.timestamp;
            policies[_msgSender()].nextPay = block.timestamp + ONE_YEAR;
        }

        emit Enrolled(_msgSender(), block.timestamp);
    }

    function remove(address user) external onlyOwner {
        require(customersDetails[user].enroll == true, "User not enrolled");
        
        customersDetails[user].activeEnd = block.timestamp;
        customersDetails[user].enroll = false;
        policies[user].status = 0;
    }

    function cancelPolicy() external nonReentrant {
        require(customersDetails[_msgSender()].enroll == true, "Not enrolled!");
        
        uint256 refundAmount = customersDetails[_msgSender()].lockedTokens;
        
        // Apply penalty if policy is cancelled within first year
        if (block.timestamp < customersDetails[_msgSender()].activestart + ONE_YEAR) {
            // 50% penalty for early cancellation
            refundAmount = refundAmount / 2;
        }
        
        // Update state before transfer (CEI pattern)
        customersDetails[_msgSender()].activeEnd = block.timestamp;
        customersDetails[_msgSender()].enroll = false;
        customersDetails[_msgSender()].lockedTokens = 0;
        policies[_msgSender()].status = 0;
        
        // Transfer refund
        if (refundAmount > 0) {
            token.safeTransfer(_msgSender(), refundAmount);
        }
        
        emit PolicyCancelled(_msgSender(), refundAmount);
    }

    function addOrganisation(address org) external onlyOwner {
        require(org != address(0), "Invalid organisation address");
        require(organisation[org] == false, "Organisation already added");
        organisation[org] = true;
        emit OrganisationAdded(org);
    }

    function removeOrganisation(address org) external onlyOwner {
        require(organisation[org] == true, "Organisation not found");
        organisation[org] = false;
        emit OrganisationRemoved(org);
    }

    function payDue() external nonReentrant {
        require(
            customersDetails[_msgSender()].enroll == true,
            "Not enrolled!"
        );
        require(
            block.timestamp >= policies[_msgSender()].nextPay &&
                block.timestamp <= policies[_msgSender()].nextPay + ONE_WEEK,
            "Payment window not open"
        );
        
        uint256 totalAmount = (ANNUAL_DUE + TRANSACTION_FEE) * (10 ** 18); // Assuming 18 decimals
        require(
            token.balanceOf(_msgSender()) >= totalAmount,
            "Insufficient tokens for due payment"
        );

        // Transfer tokens using SafeERC20
        token.safeTransferFrom(_msgSender(), address(this), totalAmount);

        // Update state
        policies[_msgSender()].lastPay = block.timestamp;
        policies[_msgSender()].nextPay = block.timestamp + ONE_YEAR;
        policies[_msgSender()].paymentCount++;

        // Add to locked tokens
        customersDetails[_msgSender()].lockedTokens += totalAmount;

        emit DuePaid(_msgSender(), totalAmount, block.timestamp);
    }

    function addClaim(address user, string memory document)
        external
        checkOrg(_msgSender())
    {
        require(user != address(0), "Invalid user address");
        require(bytes(document).length > 0, "Invalid document");
        require(customersDetails[user].enroll == true, "User not enrolled");
        require(policies[user].status == 1, "Policy not active");
        require(claimDataB[document] == address(0), "Document already exists");
        
        claimDataB[document] = user;

        emit ClaimAdded(user, document);
    }

    function claim(
        address user,
        string memory document,
        uint256 tokens
    ) external onlyOwner nonReentrant {
        require(user != address(0), "Invalid user address");
        require(
            customersDetails[user].enroll == true && policies[user].status == 1,
            "Invalid policy or not enrolled"
        );
        require(claimDataB[document] == user, "Invalid document");
        require(tokens > 0, "Claim amount must be greater than 0");
        require(tokens <= MAX_CLAIM_AMOUNT * (10 ** 18), "Claim amount exceeds maximum");
        require(token.balanceOf(address(this)) >= tokens, "Insufficient contract balance");

        // Effects: Update state BEFORE external calls (CEI pattern)
        delete claimDataB[document];
        policies[user].claimCount++;

        // Interactions: External call last
        token.safeTransfer(user, tokens); // ✅ FIXED: Send to user, not owner

        emit Claimed(user, document, tokens);
    }

    function getCustomerDetails(address user) external view returns (CustomerDetails memory) {
        return customersDetails[user];
    }

    function getPolicyDetails(address user) external view returns (PolicyHealth memory) {
        return policies[user];
    }

    function getContractBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    // Emergency withdrawal function (only owner, with safeguards)
    function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(token.balanceOf(address(this)) >= amount, "Insufficient balance");
        
        token.safeTransfer(owner(), amount);
    }
}
