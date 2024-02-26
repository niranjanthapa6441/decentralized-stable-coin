// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDSCEngine {
    function depositCollateralAndMintDSC() external;

    function depositCollateral() external;

    function redeemCollateralForDSC() external;

    function redeemCollateral() external;

    function mintDSC() external;

    function burnDSC() external;

    function liquidate() external;

    function getHealthFactor() external view;
}
