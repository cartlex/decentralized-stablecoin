//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author cartlex
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    //// ERRORS ////
    ////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__LengthMustBeTheSame();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorBelowMinimum();

    /////////////////////////
    //// STATE VARIABLES ////
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDcsMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_DecentralizedStableCoin;

    ////////////////
    //// EVENTS ////
    ////////////////
    event CollateralDeposited(
        address indexed sender, address indexed tokenCollateralAddress, uint256 indexed collateralAmount
    );

    event CollateralRedeemed(address indexed sender, uint256 indexed amountCollateral, address indexed tokenCollateralAddress);

    ///////////////////
    //// MODIFIERS ////
    ///////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
            _;
        }
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address decentralizedStableCoin) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__LengthMustBeTheSame();
        }
        uint256 i = 0;
        for (i; i < tokenAddresses.length;) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        unchecked {
            i++;
        }
        i_DecentralizedStableCoin = DecentralizedStableCoin(decentralizedStableCoin);
    }

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of token to mint.
     * @notice Deposit and mint in one transaction.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @notice follows Check-effect-interaction
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, amountCollateral, tokenCollateralAddress);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amountDscToBurn Amount DSC token to burn.
     * @param tokenCollateralAddress The collateral address to redeem.
     * @param amountCollateral Amount of collateral to redeem.
     * @notice Burns DSC token and redeems underlying collateral in one transaction.
     */
    function removeCollateral(uint256 amountDscToBurn, address tokenCollateralAddress, uint256 amountCollateral) external {
        burnDsc(amountDscToBurn);
        redeemCollateralForDsc(tokenCollateralAddress, amountCollateral);
    }

    /**
     * @param amountDscToMint The amount of decentralized stablecoins to mint.
     * @notice must have more collateral than the minimum threshhold.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_DecentralizedStableCoin.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        s_DSCMinted[msg.sender] -= amount;
        bool success = i_DecentralizedStableCoin.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_DecentralizedStableCoin.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBelowMinimum();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
    }

    function getHealthFactor() external view {}

    function _getAccountInformation(address user) private view returns (uint256, uint256) {
        uint256 totalDcsMinted = s_DSCMinted[user];
        uint256 collateralValueInUsd = getAccountCollateralValue(user);
        return (totalDcsMinted, collateralValueInUsd);
    }

    /**
     * Returns how close to liquidation a user is.
     * If a user goes below 1, then they can get liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // return collateralValueInUsd / totalDscMinted;
        // 1000 ETH * 50 = 50_000 / 100 = 500
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = (75 / 100) < 1

        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50_000 / 100 = (500 / 100) > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // (50e18 * 1e18) / (300e8 * 10e10);

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd;

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
