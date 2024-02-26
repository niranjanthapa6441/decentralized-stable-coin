// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {IDSCEngine} from "./interfaces/IDSCEngine.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DSC Engine
 * @author Niranjan Thapa
 * 
 * The system is designed to be as minimal as possible, and have the tokens maintain 
   a 1 token == $1 peg.
 * This stable coin has the properties: 
 * - Exogenous Collateral 
 * - Dollar pegged 
 * - Algorithmically Stable 
 * 
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH 
   and WBTC
 * 
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral
 < = the $ backed value of all the DSC.
 * 
 * @notice This contract is the core of the Decentralized Stable Coin system. It handles 
   all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral. 
 * @notice  This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is IDSCEngine, ReentrancyGuard {
    /* errors */
    error DSCEngine__AmountProviedShouldBeMoreThanZero(
        uint256 providedAmount,
        string requiredAmount
    );
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCENGINE__TransferFailed();

    /* state variables */
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_dsc;

    /* events */
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /* modifiers */
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__AmountProviedShouldBeMoreThanZero({
                providedAmount: _amount,
                requiredAmount: "more than zero"
            });
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /* functions */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
        i_ dsc = DecentralizedStableCoin(dscAddress);
    }

    /* external functions */
    function depositCollateralAndMintDSC() external override {}

    /**
     *
     * @param _tokenCollateralAddress The address of the token to deposit the collateral
     * @param _amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    )
        external
        override
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            _tokenCollateralAddress
        ] += _amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            _tokenCollateralAddress,
            _amountCollateral
        );

        bool success = IERC20(_tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            _amountCollateral
        );
        if (!success) {
            revert DSCENGINE__TransferFailed();
        }
    }

    function redeemCollateralForDSC() external override {}

    function redeemCollateral() external override {}

    function mintDSC() external override {}

    function burnDSC() external override {}

    function liquidate() external override {}

    function getHealthFactor() external view override {}
}
