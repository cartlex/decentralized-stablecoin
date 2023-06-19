//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    /////////////////////////
    //// STATE VARIABLES ////
    /////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_DecentralizedStableCoin;

    ////////////////
    //// EVENTS ////
    ////////////////
    event CollateralDeposited(
        address indexed sender, address indexed tokenCollateralAddress, uint256 indexed collateralAmount
    );

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
        }
        unchecked {
            i++;
        }
        i_DecentralizedStableCoin = DecentralizedStableCoin(decentralizedStableCoin);
    }

    function depositCollateralAndMintDsc() external {}

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @notice follows Check-effect-interaction
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        (bool success) = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function removeCollateral() external {}

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoins to mint.
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant{}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}

// 1:25:00 stopped
