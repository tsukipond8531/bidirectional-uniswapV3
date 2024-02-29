pragma solidity ^0.8.14;

import "./BitMath.sol";

library TickBitmap {
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick % 256));
    }

    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        require(tick % tickSpacing == 0); // ensure that the tick is spaced
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        uint256 mask = 1 << bitPos;
        self[wordPos] ^= mask;
    }

    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;

        // lte = true: selling tokenX
        // lte = false: buying tokenX
        if (lte) {
            // Get the position of the current tick
            (int16 wordPos, uint8 bitPos) = position(compressed);

            // Create a mask where all bits to the right of the current tick are set to 1, including the current tick
            // (1 << bitPos) sets the bit at bitPos to 1 eg 00010000
            // (1 << bitPos) - 1 sets the bit at bitPost to 0 and all bits to the right to 1 eg 00001111
            // + (1 << bitPos) adds the bit at bitPos back to 1 eg 000111111
            uint mask = (1 << bitPos) - 1 + (1 << bitPos);
            // & (AND operator) - if both bits are 1 then the result is 1, otherwise 0
            // Therefore we can check if the 
            // @audit: initialized can never be 0 if the tick that we are checking is initialised! Is this a problem.
            uint masked = self[wordPos] & mask;

            initialized = masked != 0;
            next = initialized 
            // This line calculates the position of the next initialised tick
            // bitPos - MSB tells you the distance from the current bitPos to the next initialised tick
            // subtracting this from compressed gives you the position of the next inited tick in the compressed scale
            // Therefore this is the next initialised tick.
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                // This line resets the pointer (`next`) to the start of the word
                // eg: compressed = 7233: This gives us `wordPos = 28` and `bitPos = 65`.
			    // 7233 - 65 = 7168. This gives us `wordPos = 28` and `bitPos = 0`.
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);

            uint mask = ~((1 << bitPos) - 1);
            uint masked = self[wordPos] & mask;

            initialized = masked != 0;

            next = initialized
                ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                // Move pointer to left most bit
                : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }
    }
}
