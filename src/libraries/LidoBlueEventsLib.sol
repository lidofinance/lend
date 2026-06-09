// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id} from "../interfaces/IMorpho.sol";

/// @title LidoBlueEventsLib
/// @author Lido Lending contributors
/// @notice Library exposing the events added by the LidoBlue fork.
library LidoBlueEventsLib {
    /// @notice Emitted when a market's controller is bound at creation.
    /// @param id The market id.
    /// @param controller The bound controller.
    event SetMarketController(Id indexed id, address indexed controller);

    /// @notice Emitted when the deleverage extension is enabled for a market at creation.
    /// @param id The market id.
    event EnableDeleverage(Id indexed id);

    /// @notice Emitted on a successful `deleverage`.
    /// @param id The market id.
    /// @param caller The caller of `deleverage`.
    /// @param onBehalf The supply-side account whose shares are burned.
    /// @param borrower The borrower whose debt and collateral are reduced.
    /// @param supplyShares The supply shares burned from `onBehalf`.
    /// @param collateralSeized The collateral seized from `borrower` and sent to the receiver.
    /// @param debtCanceled The borrow assets canceled from `borrower`.
    event Deleverage(
        Id indexed id,
        address indexed caller,
        address indexed onBehalf,
        address borrower,
        uint256 supplyShares,
        uint256 collateralSeized,
        uint256 debtCanceled
    );
}
