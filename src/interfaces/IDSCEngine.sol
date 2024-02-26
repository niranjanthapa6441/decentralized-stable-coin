// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDSCEngine {
    function depositCollateralAndMintDSC() external;

    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) external;

    function redeemCollateralForDSC() external;

    function redeemCollateral() external;

    function mintDSC() external;

    function burnDSC() external;

    function liquidate() external;

    function getHealthFactor() external view;
}
