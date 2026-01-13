//SPDX-License-Identifier:MIT

pragma solidity ^0.8.29;

import { DWebThreePavlouStableCoin } from "./DWebThreePavlouStableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { OracleLib } from "./Libraries/OracleLib.sol";
import { FlashMintDWebThreePavlou } from "./FlashMintDWebThreePavlou.sol";

/**
 * @title DSCEngine
 * @author web3pavlou
 *
 * The system is designed to have the tokens maintain 1 DWTPSC token == $1 peg
 * This stablecoin has the properties:
 * -Exogenous collateral
 * -Dollar pegged
 * -Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance,no fees and was backed only by WETH and
 * WBTC.
 *
 * DSC system enforces roughly a 200% minimum collateral
 * ratio (or a health factor of 1.0) for a user to avoid liquidation
 * Protocol should always be 'overcollateralized'.
 * At no point should the value of all collateral be less
 * than the dollar pegged value of all the DWTPSC in the system.
 * @notice This contract is the core of the DSC System .
 *
 * It gives incentives to liquidators with a fixed bonus for undercollateralized positions
 *  and allows flash - minting (EIP-3156) for anyone to mint DWTPSC up to a limit
 *
 * @notice This contract is very loosely based on the SKY protocol.
 */
contract DSCEngine is ReentrancyGuard, Ownable {
    ///////////////
    // Errors    //
    ///////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__CollateralTokenAlreadyExists(address token);
    error DSCEngine__InvalidCollateralToken(address token);
    error DSCEngine__InvalidPriceFeed(address feed);
    error DSCEngine__InvalidDsc(address i_dsc);
    error DSCEngine__NotAllowedToken();
    error DSCEngine__BurnAmountExceedsBalance();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__MissingTokenDecimals(address token);
    error DSCEngine__MissingFeedDecimals(address token);
    error DSCEngine__BelowMinPositionValue(uint256 positionValueUsd, uint256 minRequiredUsd);
    error DSCEngine__RemainingDebtBelowMinThreshold(uint256 remainingDebt, uint256 minThreshold);
    error DSCEngine__BatchLengthMismatch();
    error DSCEngine__BatchEmpty();
    error DSCEngine__MaxPriceAgeMustBeMoreThanZero();

    // Flash mint
    error DSCEngine__UnsupportedFlashToken();
    error DSCEngine__InvalidFlashMinter();
    error DSCEngine__InvalidFlashFeeBps(uint256 newFlashFeeBps);

    /////////////////
    // Libraries   //
    /////////////////
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;

    /////////////////////
    // State Variables //
    /////////////////////

    uint256 private constant PRECISION = 1e18; // units for precise calculations - normalization
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // healthy position: collValue*(threshold/PRECISION)>=debt.
    uint256 private constant LIQUIDATION_PRECISION = 100; // threshold as a percentage(200% overcollateralization)
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // if drops below -> user is liquidatable
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus
    uint256 private constant BASE_TEN = 10; // Used for exponentiating to token/feed decimals

    // Flash mint
    uint256 private constant MAX_FLASH_MINT_AMOUNT = 1_000_000e18; // global cap
    uint256 private constant BPS_PRECISION = 10_000; // Flash loan fee in basis points

    uint256 private s_flashFeeBps = 0; // Flash loan fee in basis points (parts per 10_000). Default = 0.

    /// @dev Contract that actually executes flash mint logic (minting and callback handling).
    FlashMintDWebThreePavlou public flashMinter;

    /// @notice Minimum USD value of collateral required to open a position.
    uint256 private s_minPositionValueUsd = 250e18;

    mapping(address collateralToken => address priceFeed) s_priceFeeds;
    /// @notice max allowed price age (in seconds) for the underlying feed. If not set, uses a default from OracleLib (3
    /// hours).
    mapping(address token => uint256 maxPriceAge) s_maxPriceAge;
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    mapping(address tokenAddress => uint8 decimals) private s_tokenDecimals;
    mapping(address token => uint8 decimals) private s_feedDecimals;

    /// @notice Minimum remaining debt threshold per collateral token.
    /// Prevents leaving small "dust" debt positions after partial liquidations.
    /// Unit: USD with 18 decimals (same as _getUsdValue returns).
    mapping(address token => uint256) private s_minDebtThreshold;

    address[] s_collateralTokens;
    DWebThreePavlouStableCoin private immutable i_dsc; // The stablecoin token contract (ERC20) managed by this engine

    address private immutable i_flashFeeRecipient; // sets the engine as the administrative authority of the
        // surplus (fee)s

    //////////////
    // Events   //
    //////////////

    event CollateralTokenAdded(
        address indexed token, address indexed priceFeed, uint8 tokenDecimals, uint8 feedDecimals
    );
    event DscMinted(address indexed user, uint256 amount);
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );
    event DscBurned(address indexed onBehalfOf, address indexed dscFrom, uint256 amount, bool wasFlashRepayment);
    event Liquidation(
        address indexed liquidator,
        address indexed user,
        address indexed collateral,
        uint256 debtBurned,
        uint256 collateralSeized
    );
    event MinPositionValueUsdChanged(uint256 indexed newMinPositionValueUsd);
    event MinDebtThresholdUpdated(address indexed token, uint256 indexed newMinDebtThresholdUsd);

    event FlashMinterUpdated(address indexed newFlashMinter);

    event FlashFeeBpsUpdated(uint256 oldFlashFeeBps, uint256 newFlashFeeBps);
    event MaxPriceAgeUpdated(address indexed token, uint256 maxPriceAge);

    ///////////////
    // Modifiers //
    ///////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////

    /// @param tokenAddresses List of allowed collateral token addresses (e.g., WETH, WBTC).
    /// @param priceFeedAddresses Chainlink USD price feeds for each collateral token.
    /// @param dscAddress Address of the DWTPSC token contract.
    /// @param initialOwner Initial owner/admin of the engine (can later transfer ownership).
    /// @notice Deploys the engine and registers allowed collateral + their price feeds and decimals.
    /// Deployment / wiring sequence:
    ///  1) Deploy DWTPSC with a temporary owner (usually the deployer EOA).
    ///  2) Deploy DSCEngine (this constructor).
    ///  3) Transfer DWTPSC ownership to DSCEngine: dsc.transferOwnership(address(dsce)).
    ///  4) Deploy `FlashMintDWebThreePavlou(dsce,dsc)`.
    ///  5) Call dsce.setFlashMinter(address(flashMinter)) .
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress,
        address initialOwner
    )
        Ownable(initialOwner)
    {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address token = tokenAddresses[i];
            address feed = priceFeedAddresses[i];

            if (s_priceFeeds[token] != address(0)) revert DSCEngine__CollateralTokenAlreadyExists(token);
            if (token == address(0) || token.code.length == 0) revert DSCEngine__InvalidCollateralToken(token);
            if (feed == address(0) || feed.code.length == 0) revert DSCEngine__InvalidPriceFeed(feed);

            s_priceFeeds[token] = feed;
            s_collateralTokens.push(token);

            uint8 tDec = IERC20Metadata(token).decimals();
            uint8 fDec = AggregatorV3Interface(feed).decimals();

            s_tokenDecimals[token] = tDec;
            s_feedDecimals[token] = fDec;

            emit CollateralTokenAdded(token, feed, tDec, fDec);
        }

        if (dscAddress == address(0) || dscAddress.code.length == 0) revert DSCEngine__InvalidDsc(dscAddress);
        i_dsc = DWebThreePavlouStableCoin(dscAddress);

        // Flash minter is intentionally unset here; it must be set via setFlashMinter() post-deploy.
        i_flashFeeRecipient = address(this);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    )
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        nonReentrant
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransferFrom(msg.sender, address(this), amountCollateral);
    }

    /**
     * follows CEI
     * @param amountDscToMint: The amount of DWTPSC to mint (in 18-decimal precision).
     * @notice They must have more collateral value than the min
     *  @dev Increases debt (DSC minted) and issues new stablecoins to the account.
     * Requires that your collateral value is at least `s_minPositionValueUsd` (e.g. $250) and hf >= 1.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        uint256 collateralValueInUsd = getAccountCollateralValue(msg.sender);
        if (collateralValueInUsd < s_minPositionValueUsd) {
            revert DSCEngine__BelowMinPositionValue(collateralValueInUsd, s_minPositionValueUsd);
        }

        s_DSCMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
        emit DscMinted(msg.sender, amountDscToMint);
    }

    /**
     * @notice Burn DWTPSC from your account to reduce your debt.
     * @param amount The amount of DWTPSC to burn
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
    }

    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @dev Combines `burnDsc` and `redeemCollateral` in one step for convenience,
     * reducing debt and retrieving collateral simultaneously
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    )
        external
        nonReentrant
        moreThanZero(amountCollateral)
        moreThanZero(amountDscToBurn)
        isAllowedToken(tokenCollateralAddress)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Withdraw a specified amount of collateral from the protocol(reduces your collateral balance).
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of that collateral to redeem back to your wallet.
     * @dev This will not burn any DWTPSC, so it effectively raises your leverage (increases risk).
     */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        nonReentrant
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Liquidate an undercollateralized position by burning DSC and
     * seizing collateral.
     * @param collateral The address of the collateral token to seize from
     * the user.
     * @param user The account with an unhealthy position (health factor <
     * 1) to be liquidated.
     * @param debtToCover The amount of DWTPSC debt the liquidator will
     * repay (burn) on the user's behalf.
     * @dev If `user`'s health factor is below 1.0, a liquidator can burn up
     * to the user's total DSC debt to improve it.
     * The liquidator receives an equivalent USD value of the specified
     * collateral, plus a 10% bonus.
     * Reverts if the position is healthy (HF >= 1), if `debtToCover` is
     * zero, or if the token is not allowed collateral.
     * Also reverts if liquidation would leave a tiny leftover debt below
     * the minimum threshold for that collateral.
     * @dev slippage protection is not implemented.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    )
        external
        nonReentrant
        isAllowedToken(collateral)
        moreThanZero(debtToCover)
    {
        _liquidateInternal(collateral, user, debtToCover);
    }

    /**
     * @notice Perform multiple liquidations in a single transaction.
     * @notice This can be used by off-chain keepers to save gas amortized over many
     * liquidations.
     * @param collateral The address of the collateral token to seize from all the listed users.
     * @param users An array of user addresses to liquidate.
     * @param debtsToCover An array of DSC debt amounts to burn for each corresponding user in `users`.
     * @dev This will attempt `_liquidateInternal` on each (user,debtToCover) pair in the array.
     * If any liquidation fails (reverts), the entire batch is reverted(atomic batch).
     *
     */
    function batchLiquidate(
        address collateral,
        address[] memory users,
        uint256[] memory debtsToCover
    )
        external
        nonReentrant
        isAllowedToken(collateral)
    {
        uint256 len = users.length;
        if (len == 0) {
            revert DSCEngine__BatchEmpty();
        }
        if (len != debtsToCover.length) {
            revert DSCEngine__BatchLengthMismatch();
        }

        for (uint256 i = 0; i < len; i++) {
            uint256 amount = debtsToCover[i];
            if (amount == 0) {
                revert DSCEngine__NeedsMoreThanZero();
            }
            _liquidateInternal(collateral, users[i], amount);
        }
    }

    ///////////////////////
    // Flash Minting     //
    ///////////////////////

    function burnProtocolFees(uint256 amount) external onlyOwner {
        i_dsc.burn(amount); // burns from DSCEngine balance
    }

    ///////////////
    // Setters  ///
    ///////////////

    /**
     * @notice Update the minimum collateral value (in USD) required to mint any DWTPSC.
     * @param newMinPositionValueUsd The new minimum position value in 18 - decimal USD terms.
     * @dev Only callable by the owner. Prevents users from opening
     * positions below this value. Useful to adjust based on gas costs or risk considerations.
     */

    function setMinPositionValueUsd(uint256 newMinPositionValueUsd)
        external
        onlyOwner
        moreThanZero(newMinPositionValueUsd)
    {
        s_minPositionValueUsd = newMinPositionValueUsd;
        emit MinPositionValueUsdChanged(newMinPositionValueUsd);
    }

    /**
     * @notice Set the minimum remaining debt threshold for a given
     * collateral, in USD.
     * @param token The collateral token address for which to set the threshold.
     * @param minDebtThreshold The minimum remaining debt (in 18-decimal USD) allowed after partial liquidation.
     * @dev Only owner can call. If a liquidation would leave less than this amount of debt for the user, the
     * liquidation will revert (forcing the liquidator to burn more debt to fully clear it or leave a larger remainder).
     * This is typically set to a value that makes economic sense to liquidate (to avoid tiny unprofitable leftover
     * debts).
     */

    function setMinDebtThreshold(
        address token,
        uint256 minDebtThreshold
    )
        external
        onlyOwner
        isAllowedToken(token)
    {
        s_minDebtThreshold[token] = minDebtThreshold;
        emit MinDebtThresholdUpdated(token, minDebtThreshold);
    }

    /**
     * @notice Update the flash loan fee (in basis points).
     * @param newFlashFeeBps The new fee in basis points (parts per 10,000).
     * @dev Only owner. For example, 5 = 0.05%, 50 = 0.5%, 0 = no fee.
     * Cannot exceed 10,000 (100%).
     */

    function setFlashFeeBps(uint256 newFlashFeeBps) external onlyOwner {
        if (newFlashFeeBps > BPS_PRECISION) {
            revert DSCEngine__InvalidFlashFeeBps(newFlashFeeBps);
        }
        uint256 old = s_flashFeeBps;
        s_flashFeeBps = newFlashFeeBps;
        emit FlashFeeBpsUpdated(old, newFlashFeeBps);
    }

    /**
     * @notice Update the flash minting contract address.
     * @param newMinter The address of the new FlashMintDWebThreePavlou contract.
     * @dev Only owner. The new contract must be a deployed FlashMintDWebThreePavlou that is configured to use this
     * DSCEngine and the same DWTPSC token.
     * This function also updates the DWTPSC token's minter to the new
     * contract (DSCEngine must be the token owner for this to succeed).
     */

    function setFlashMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) revert DSCEngine__InvalidFlashMinter();
        //the address must be a deployed contract
        if (newMinter.code.length == 0) revert DSCEngine__InvalidFlashMinter();

        if (FlashMintDWebThreePavlou(newMinter).getDsce() != address(this)) {
            revert DSCEngine__InvalidFlashMinter();
        }
        if (FlashMintDWebThreePavlou(newMinter).getDsc() != address(i_dsc)) {
            revert DSCEngine__InvalidFlashMinter();
        }

        flashMinter = FlashMintDWebThreePavlou(newMinter);

        // DSCEngine must be the owner of DSC for this to work
        i_dsc.setMinter(newMinter);

        emit FlashMinterUpdated(newMinter);
    }

    /**
     * @notice Set the maximum acceptable price age for a collateral's price feed.
     * @param token The collateral token address.
     * @param maxPriceAge The max age of the Chainlink price (in seconds) that is considered valid.
     * @dev Only owner. If the price feed's data is older than `maxPriceAge`, the oracle library will treat it as stale
     * and cause transactions to revert (for safety).
     * This can override the default of 3 hours for specific chains.
     * Emits a `MaxPriceAgeUpdated` event.
     */

    function setMaxPriceAge(address token, uint256 maxPriceAge) external onlyOwner isAllowedToken(token) {
        if (maxPriceAge == 0) {
            revert DSCEngine__MaxPriceAgeMustBeMoreThanZero();
        }
        s_maxPriceAge[token] = maxPriceAge;
        emit MaxPriceAgeUpdated(token, maxPriceAge);
    }

    ////////////////////////////////////
    // Private and Internal Functions //
    ////////////////////////////////////

    function _liquidateInternal(address collateral, address user, uint256 debtToCover) internal {
        // 1. Check target user is actually liquidatable, Can't liquidate a healthy position (HF >= 1)
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // 2. Clamp `debtToCover` to the user's total DSC debt so we never over-burn
        uint256 userDebt = s_DSCMinted[user];
        if (userDebt == 0) {
            revert DSCEngine__BurnAmountExceedsBalance();
        }

        uint256 actualDebtToBurn = debtToCover > userDebt ? userDebt : debtToCover;

        // Cap the debt to burn such that we don't burn more than the collateral's USD value. (Cannot burn $1000 debt if
        // only $500 worth of this collateral is deposited.)
        uint256 totalDepositedCollateral = s_collateralDeposited[user][collateral];
        uint256 positionValueUsd = _getUsdValue(collateral, totalDepositedCollateral);

        if (actualDebtToBurn > positionValueUsd) {
            actualDebtToBurn = positionValueUsd;
        }

        // Enforce minDebtThreshold dust rule
        uint256 minDebtThreshold = s_minDebtThreshold[collateral];
        if (minDebtThreshold > 0) {
            uint256 remainingDebt = userDebt - actualDebtToBurn;
            if (remainingDebt > 0 && remainingDebt < minDebtThreshold) {
                revert DSCEngine__RemainingDebtBelowMinThreshold(remainingDebt, minDebtThreshold);
            }
        }

        // 3. Calculate collateral to redeem for the debt: tokenAmountFromDebtCovered = the exact collateral needed
        // to cover`actualDebtToBurn` at current price. bonusCollateral = 10% of that amount, as an extra reward.
        // totalCollateralToRedeem = base + bonus (this is what the liquidator will seize).

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, actualDebtToBurn);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // If the user doesn't have enough collateral to pay the full 10% bonus, reduce the bonus to the
        // maximum available. This avoids a situation where a user at 105% collateralization (just above 100% debt)
        // could not be liquidated at all
        if (totalCollateralToRedeem > totalDepositedCollateral) {
            uint256 availableBonus = totalDepositedCollateral > tokenAmountFromDebtCovered
                ? totalDepositedCollateral - tokenAmountFromDebtCovered
                : 0;

            totalCollateralToRedeem = tokenAmountFromDebtCovered + availableBonus;
        }

        // 4. Effects / Interactions
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender); // Decrease user's collateral and send
            // the calculated amount to the liquidator

        _burnDsc(actualDebtToBurn, user, msg.sender); //Burn actualDebtToBurn DSC from the liquidator to reduce the
            // user's debt by that amount. The liquidator must have provided this DSC

        // 5. Ensure the liquidation actually improved the user's health factor (it should in all valid cases).
        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        emit Liquidation(msg.sender, user, collateral, actualDebtToBurn, totalCollateralToRedeem);
    }

    // handle collateral withdrawal from one account to another.
    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    )
        private
    {
        // Removes `amount` of `tokenCollateral` from `from`'s deposited balance and transfers it to `to`.
        // Used for both user redemption (from = user, to = user) and liquidation (from = user, to = liquidator).
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransfer(to, amountCollateral);
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        uint256 minted = s_DSCMinted[onBehalfOf];
        if (minted < amountDscToBurn) revert DSCEngine__BurnAmountExceedsBalance();

        IERC20(address(i_dsc)).safeTransferFrom(dscFrom, address(this), amountDscToBurn);

        s_DSCMinted[onBehalfOf] = minted - amountDscToBurn;
        i_dsc.burn(amountDscToBurn);

        emit DscBurned(onBehalfOf, dscFrom, amountDscToBurn, false);
    }

    //////////////////////////////////////////////
    // Internal & Private View & Pure Functions //
    //////////////////////////////////////////////

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _flashFee(address token, uint256 amount) internal view returns (uint256) {
        if (token != address(i_dsc)) revert DSCEngine__UnsupportedFlashToken();
        if (amount == 0 || s_flashFeeBps == 0) return 0;
        return Math.mulDiv(amount, s_flashFeeBps, BPS_PRECISION, Math.Rounding.Ceil);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    // Get latest price for `token` in USD. OracleLib ensures the price is fresh (not older than maxPriceAge) and within
    // preset bounds (not zero or absurdly out of range). If the price is stale or invalid, this call will revert
    // (protecting the system from outdated prices).
    function _getUsdValue(address token, uint256 amount) private view isAllowedToken(token) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        uint256 maxPriceAge = s_maxPriceAge[token];
        if (maxPriceAge == 0) {
            maxPriceAge = OracleLib.getTimeOut(priceFeed);
        }
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData(maxPriceAge);

        uint8 feedDecimals = s_feedDecimals[token];
        if (feedDecimals == 0) revert DSCEngine__MissingFeedDecimals(token);

        uint8 tokenDecimals = s_tokenDecimals[token];
        if (tokenDecimals == 0) revert DSCEngine__MissingTokenDecimals(token);

        uint256 normalizedAmount = (amount * PRECISION) / (BASE_TEN ** tokenDecimals);
        uint256 normalizedPrice = (uint256(price) * PRECISION) / (BASE_TEN ** feedDecimals);

        return (normalizedAmount * normalizedPrice) / PRECISION;
    }

    function _totalSystemCollateralValueUsd() private view returns (uint256 totalCollateralValueInUsd) {
        // totalCollateralValueUsd is the aggregate USD worth of all collateral in the contract.
        // The idea is to not allow flash minting more DWTPSC than the system collateral value (to maintain theoretical
        // full backing during the flash loan). If that value exceeds the hard cap (1,000,000 tokens), cap the flash
        // loan at the hard limit.

        uint256 len = s_collateralTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = s_collateralTokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;
            totalCollateralValueInUsd += _getUsdValue(token, balance);
        }
    }

    function _maxFlashLoanInternal() internal view returns (uint256) {
        uint256 totalCollateralValueUsd = _totalSystemCollateralValueUsd();
        uint256 supply = i_dsc.totalSupply(); // 18 decimals

        // If already underwater, don't allow any flash mint headroom.
        if (totalCollateralValueUsd <= supply) return 0;

        uint256 headroom = totalCollateralValueUsd - supply;

        // bound by global ceiling
        if (headroom > MAX_FLASH_MINT_AMOUNT) return MAX_FLASH_MINT_AMOUNT;
        return headroom;
    }

    //////////////////////////////////////////////
    //// Public & External View & Pure Function //
    //////////////////////////////////////////////

    // We want the token amount such that token_amount * price >= usdAmountInWei.
    // Compute: token_amount = ceil(usdAmount * (10^tokenDecimals) /normalizedPrice).
    // Using Math.mulDiv with rounding up to avoid under-calculating (ensures the returned token amount covers the USD
    // value needed)
    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    )
        public
        view
        isAllowedToken(token)
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        uint256 maxPriceAge = s_maxPriceAge[token];
        if (maxPriceAge == 0) {
            maxPriceAge = OracleLib.getTimeOut(priceFeed);
        }
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData(maxPriceAge);

        uint8 feedDecimals = s_feedDecimals[token];
        if (feedDecimals == 0) revert DSCEngine__MissingFeedDecimals(token);

        uint8 tokenDecimals = s_tokenDecimals[token];
        if (tokenDecimals == 0) revert DSCEngine__MissingTokenDecimals(token);

        uint256 normalizedPrice = (uint256(price) * PRECISION) / (BASE_TEN ** feedDecimals);

        uint256 tokenAmount =
            Math.mulDiv(usdAmountInWei, BASE_TEN ** tokenDecimals, normalizedPrice, Math.Rounding.Ceil);

        return tokenAmount;
    }

    // Sum all collateral deposits by the user, converted to USD. (Iterates over all allowed collateral types)
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != address(i_dsc)) return 0;
        return _maxFlashLoanInternal();
    }

    /**
     * @notice Default 0
     * @param token The address of the token (must be DWTPSC for a non-zero
     * fee).
     * @param amount The amount of tokens to borrow.
     * loan.
     */
    function flashFee(address token, uint256 amount) external view returns (uint256) {
        if (token != address(i_dsc) || amount == 0) return 0;
        return _flashFee(token, amount);
    }

    // HF = (collateral_USD * liquidationThreshold / 100) / debt_USD, scaled by 1e18.
    // With threshold=50, this is (collateral_USD * 0.5 / debt_USD) * 1e18.
    // So if collateral_USD = 2 * debt_USD, HF = (2 * 0.5 / 1)*1e18 = 1e18(healthy). If collateral drops below 2x debt,
    // HF < 1e18 (unsafe).
    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getMinPositionValueUsd() external view returns (uint256) {
        return s_minPositionValueUsd;
    }

    function getFlashFeeRecipient() external view returns (address) {
        return i_flashFeeRecipient;
    }

    function getFlashMinter() external view returns (address) {
        return address(flashMinter);
    }

    function getMinDebtThreshold(address token) external view returns (uint256) {
        return s_minDebtThreshold[token];
    }

    function getFlashFeeBps() external view returns (uint256) {
        return s_flashFeeBps;
    }

    function getFeedDecimals(address token) external view returns (uint8) {
        return s_feedDecimals[token];
    }

    function getTokenDecimals(address token) external view returns (uint8) {
        return s_tokenDecimals[token];
    }

    function getMaxPriceAge(address token) external view returns (uint256) {
        return s_maxPriceAge[token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getBaseTen() external pure returns (uint256) {
        return BASE_TEN;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }
}
