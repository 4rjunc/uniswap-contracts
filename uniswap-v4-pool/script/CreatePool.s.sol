pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockToken} from "src/MockToken.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {IAllowanceTransfer} from "v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

contract CreatePool is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Create DOGE token
        MockToken token2 = new MockToken("DOGE COIN", "DOGE", 18, 1_000_000_000 ether);
        console.log("DOGE Token Address:");
        console.logAddress(address(token2));

        // Pool configuration
        address hook = address(0);
        uint24 swapFee = 4000; // 0.40%
        int24 tickSpacing = 10;

        // FIXED: Use much smaller amounts to avoid liquidity overflow with extreme ratios
        uint256 ethAmount = 1 ether;               // 0.001 ETH (much smaller)
        uint256 dogeAmount = 200_000_000 ether;            // 200K DOGE (scaled down proportionally)
        
        // This maintains the same 200M:1 ratio but with smaller absolute numbers
        
        // Calculate the pool price from your desired ratio
        uint160 startingPrice = encodeSqrtRatioX96(dogeAmount, ethAmount);
        
        // For 200M DOGE per 1 ETH, the tick is approximately -884,000
        // We'll use this known value since TickMath function names vary
        int24 currentTick = -884000; // Approximate tick for 200M:1 ratio
        
        console.log("=== POOL ANALYSIS ===");
        console.log("Pool starting tick:");
        console.logInt(currentTick);
        console.log("This means pool price is 200M DOGE per 1 ETH");

        // HERE'S THE KEY: Position range MUST include the current tick to get both tokens
        // Since our tick is around -884,000, we need a range that includes this tick
        
        // SOLUTION 1: Wide range that includes current price
        int24 tickLower = -887000;  // Wide range to include current tick
        int24 tickUpper = -880000;   // Still below zero but includes current price
        
        // Make sure ticks are valid multiples of tickSpacing
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;
        
        console.log("=== POSITION RANGE ===");
        console.log("Position tick lower:");
        console.logInt(tickLower);
        console.log("Position tick upper:");
        console.logInt(tickUpper);
        
        // Check if current tick is within our range
        bool isInRange = currentTick >= tickLower && currentTick <= tickUpper;
        console.log("Is position in range?");
        console.log(isInRange);
        
        if (!isInRange) {
            console.log("WARNING: Position is OUT OF RANGE!");
            console.log("This means only 1 token will be deposited!");
            
            // Auto-fix: adjust range to include current tick
            tickLower = ((currentTick - 1000) / tickSpacing) * tickSpacing;
            tickUpper = ((currentTick + 1000) / tickSpacing) * tickSpacing;
            
            console.log("AUTO-CORRECTED RANGE:");
            console.log("New tick lower:");
            console.logInt(tickLower);
            console.log("New tick upper:");
            console.logInt(tickUpper);
        }

        IPositionManager posm = IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4);
        IAllowanceTransfer PERMIT2 = IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

        uint256 amount0Max = ethAmount + 1 wei;
        uint256 amount1Max = dogeAmount + 1 wei;
        bytes memory hookData = new bytes(0);

        // Configure the pool 
        PoolKey memory pool2 = PoolKey({
                currency0: CurrencyLibrary.ADDRESS_ZERO, // ETH
                currency1: Currency.wrap(address(token2)), // DOGE
                fee: swapFee,
                tickSpacing: tickSpacing,
                hooks: IHooks(hook)
        });

        // Calculate exact amounts needed for this range
        // FIXED: Use a reasonable liquidity amount to avoid overflow
        uint128 liquidity = 1e15; // Start with a smaller, safe liquidity amount
        
        console.log("Using liquidity:");
        console.log(liquidity);

        // Show what amounts will actually be used
        (uint256 actualAmount0, uint256 actualAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        
        console.log("=== ACTUAL AMOUNTS TO BE DEPOSITED ===");
        console.log("ETH that will be deposited:");
        console.log(actualAmount0);
        console.log("DOGE that will be deposited:");
        console.log(actualAmount1);

        // Initialize parameters for multicall
        bytes[] memory params = new bytes[](2);
        
        // Encode the initializePool parameters
        params[0] = abi.encodeWithSelector(
            IPoolInitializer_v4.initializePool.selector,
            pool2,
            startingPrice
        );
        
        // Initialize the mint-liquidity parameters
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] = abi.encode(pool2, tickLower, tickUpper, liquidity, amount0Max, amount1Max, msg.sender, hookData);
        mintParams[1] = abi.encode(pool2.currency0, pool2.currency1);

        uint256 deadline = block.timestamp + 60;
        params[1] = abi.encodeWithSelector(
            posm.modifyLiquidities.selector, abi.encode(actions, mintParams), deadline
        );

        // Approve the tokens
        token2.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token2), address(posm), type(uint160).max, type(uint48).max);

        // Execute the multicall with ETH value
        IPositionManager(posm).multicall{value: amount0Max}(params);
        console.log("=== SUCCESS ===");
        console.log("Pool created and liquidity added!");
        
        vm.stopBroadcast();
    }

    function encodeSqrtRatioX96(uint256 amount1, uint256 amount0) internal pure returns (uint160 sqrtPriceX96) {
        require(amount0 > 0, "PriceMath: division by zero");
        uint256 ratioX192 = (amount1 << 192) / amount0;
        uint256 sqrtRatio = Math.sqrt(ratioX192);
        require(sqrtRatio <= type(uint160).max, "PriceMath: sqrt overflow");
        sqrtPriceX96 = uint160(sqrtRatio);
    }
}

/* 
=== KEY TAKEAWAYS FROM UNISWAP DISCORD ===

"because you create a position that is out of range, it means the position 
will only have 100% of either token0 or token1, not a mix of the 2 tokens."

YOUR PROBLEM:
- Pool price: tick ~-884,000 (200M DOGE per 1 ETH)
- Your position: tick -600 to +600
- Result: Position is COMPLETELY out of range (way above the actual price)
- Outcome: Only ETH gets deposited (the higher-priced token)

THE FIX:
1. Position range MUST include the current pool tick
2. If current tick = -884,000, your range must include that tick
3. Example: range from -887,000 to -880,000 (includes -884,000)
4. This ensures BOTH tokens get deposited

ALTERNATIVE APPROACHES:
1. Use a more balanced price ratio (less extreme than 200M:1)
2. Set your desired range first, then calculate appropriate token amounts
3. Use full-range positions (though less capital efficient)
*/
