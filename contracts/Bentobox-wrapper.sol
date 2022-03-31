// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.4;

import { ERC20, ERC4626 } from "@rari-capital/solmate/src/mixins/ERC4626.sol";
import { IBentoBox, IFlashBorrowerBentoBoxVersion } from "./interfaces/bentobox/IBentoBox.sol";
import { IERC3156FlashLender } from "./interfaces/ERC3156/IERC3156FlashLender.sol";
import { IERC3156FlashBorrower } from "./interfaces/ERC3156/IERC3156FlashBorrower.sol";

contract BentoBoxWrapper is ERC4626, IERC3156FlashLender, IFlashBorrowerBentoBoxVersion {
    IBentoBox public immutable bentoBox;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 private constant FLASH_LOAN_FEE = 50; // 0.05%
    uint256 private constant FLASH_LOAN_FEE_PRECISION = 1e5;

    constructor(ERC20 asset, IBentoBox _bentoBox) ERC4626(asset, asset.name(), asset.symbol()) {
        bentoBox = _bentoBox;
        asset.approve(address(bentoBox), type(uint256).max);
    }

    function totalAssets() public view override returns (uint256) {
        return bentoBox.toAmount(asset, bentoBox.balanceOf(asset, address(this)), false);
    }

    function afterDeposit(uint256 assets, uint256) internal override {
        bentoBox.deposit(asset, address(this), address(this), assets, 0);
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        bentoBox.withdraw(asset, address(this), address(this), assets, 0);
    }

    /**
     * @dev Loan `amount` tokens to `receiver`, and takes it back plus a `flashFee` after the callback.
     * @param receiver The contract receiving the tokens, needs to implement the `onFlashLoan(address user, uint256 amount, uint256 fee, bytes calldata)` interface.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param data A data parameter to be passed on to the `receiver` for any custom use.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        bytes memory dataToPass = abi.encode(msg.sender, receiver, data);
        bentoBox.flashLoan(
            IFlashBorrowerBentoBoxVersion(address(this)),
            address(receiver),
            ERC20(token),
            amount,
            dataToPass
        );
        return true;
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        require(token == address(asset), "FlashLender: Unsupported currency");
        return _flashFee(token, amount);
    }

    /**
     * @dev The fee to be charged for a given loan. Internal function with no checks.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function _flashFee(address, uint256 amount) internal pure returns (uint256) {
        return (amount * FLASH_LOAN_FEE) / FLASH_LOAN_FEE_PRECISION;
    }

    /**
     * @dev The amount of currency available to be lended.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) external view override returns (uint256) {
        return token == address(asset) ? ERC20(token).balanceOf(address(bentoBox)) : 0;
    }

    /// @notice The flashloan callback. `amount` + `fee` needs to repayed to msg.sender before this call returns.
    /// @param sender The address of the invoker of this flashloan.
    /// @param token The address of the token that is loaned.
    /// @param amount of the `token` that is loaned.
    /// @param fee The fee that needs to be paid on top for this loan. Needs to be the same as `token`.
    /// @param data Additional data that was passed to the flashloan function.
    function onFlashLoan(
        address sender,
        ERC20 token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external {
        require(sender == address(this), "FlashBorrower: Invalid initiator");
        require(token == asset, "FlashLender: Unsupported currency");
        // decode data
        (address origin, IERC3156FlashBorrower receiver, bytes memory userData) = abi.decode(
            data,
            (address, IERC3156FlashBorrower, bytes)
        );
        require(
            receiver.onFlashLoan(origin, address(token), amount, fee, userData) == CALLBACK_SUCCESS,
            "FlashLender: Callback failed"
        );
        require(
            ERC20(token).transferFrom(address(receiver), address(bentoBox), amount + fee),
            "FlashLender: Repay failed"
        );
    }
}
