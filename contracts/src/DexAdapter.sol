// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "./interfaces/IStockgift.sol";

/// @notice Uniswap SwapRouter02 (IV3SwapRouter) multi-hop entrypoint. Note: no deadline field.
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title DexAdapter
/// @notice Uniswap v3 implementation of IDexAdapter using admin-curated routes (encoded v3 paths).
///         Stateless between calls: it never holds user balances after a swap.
/// @dev Enforces the deadline itself because SwapRouter02.exactInput has none.
contract DexAdapter is AccessControl, ReentrancyGuard, IDexAdapter {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    /// @notice Optional hub token (USDG): if no direct route exists, tokenIn->hub->tokenOut is composed.
    address public hub;
    mapping(address => mapping(address => bytes)) internal _paths;

    event RouteSet(address indexed tokenIn, address indexed tokenOut, bytes path);
    event HubSet(address indexed hub);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    error NoRoute(address tokenIn, address tokenOut);
    error BadPath();
    error DeadlinePassed();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error ZeroAddress();

    constructor(address admin, address router_) {
        if (admin == address(0) || router_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        router = ISwapRouter02(router_);
    }

    /// @notice Set a Uniswap v3 path (tokenIn | fee | [token | fee]* | tokenOut). Empty path deletes.
    function setRoute(address tokenIn, address tokenOut, bytes calldata path) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (path.length != 0) {
            if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadPath();
            if (address(bytes20(path[0:20])) != tokenIn || address(bytes20(path[path.length - 20:])) != tokenOut) {
                revert BadPath();
            }
        }
        _paths[tokenIn][tokenOut] = path;
        emit RouteSet(tokenIn, tokenOut, path);
    }

    function setHub(address hub_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hub = hub_;
        emit HubSet(hub_);
    }

    /// @notice Effective path: the direct route, else tokenIn->hub->tokenOut, else empty.
    function getRoute(address tokenIn, address tokenOut) public view returns (bytes memory) {
        bytes memory direct = _paths[tokenIn][tokenOut];
        address h = hub;
        if (direct.length != 0 || h == address(0) || tokenIn == h || tokenOut == h) return direct;
        bytes memory a = _paths[tokenIn][h];
        bytes memory b = _paths[h][tokenOut];
        if (a.length == 0 || b.length == 0) return "";
        // a = tokenIn|fee|...|hub ; b = hub|fee|...|tokenOut -> drop b's leading hub address
        bytes memory tail = new bytes(b.length - 20);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = b[i + 20];
        }
        return bytes.concat(a, tail);
    }

    /// @inheritdoc IDexAdapter
    function hasRoute(address tokenIn, address tokenOut) external view returns (bool) {
        return getRoute(tokenIn, tokenOut).length != 0;
    }

    /// @inheritdoc IDexAdapter
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (recipient == address(0)) revert ZeroAddress();
        bytes memory path = getRoute(tokenIn, tokenOut);
        if (path.length == 0) revert NoRoute(tokenIn, tokenOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        amountOut = router.exactInput(
            ISwapRouter02.ExactInputParams({
                path: path,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}
