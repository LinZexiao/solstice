// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

type FixedU18 is uint256;

using {
    unsafeAdd as +,
    unsafeSub as -,
    unsafeMulDown as *,
    divDown as /,
    mod as %,
    equals as ==,
    greaterThan as >,
    lessThan as <,
    greaterThanOrEqualTo as >=,
    lessThanOrEqualTo as <=
} for FixedU18 global;

using FixedU18Library for FixedU18 global;

uint256 constant ONE_WAD = 1 ether;
FixedU18 constant ONE = FixedU18.wrap(ONE_WAD);
FixedU18 constant ZERO = FixedU18.wrap(0);

// type(uint256).max / ONE_WAD
uint256 constant MAX_DIVIDEND_WAD = 115792089237316195423570985008687907853269984665640564039457;
FixedU18 constant MAX_DIVIDEND = FixedU18.wrap(MAX_DIVIDEND_WAD);

error DividendTooLarge(FixedU18 dividend);
bytes4 constant DIVIDEND_TOO_LARGE_SELECTOR = 0x7b5479ff;

// @dev returns zero if divisor is zero
function divDown(FixedU18 dividend, FixedU18 divisor) pure returns (FixedU18 quotient) {
    assembly ("memory-safe") {
        if gt(dividend, MAX_DIVIDEND_WAD) {
            mstore(0, DIVIDEND_TOO_LARGE_SELECTOR)
            mstore(32, dividend)
            revert(28, 36)
        }
        quotient := div(mul(dividend, ONE_WAD), divisor)
    }
}

// @dev returns zero if divisor is zero
function mod(FixedU18 dividend, FixedU18 divisor) pure returns (FixedU18 remainder) {
    assembly ("memory-safe") {
        if gt(dividend, MAX_DIVIDEND_WAD) {
            mstore(0, DIVIDEND_TOO_LARGE_SELECTOR)
            mstore(32, dividend)
            revert(28, 36)
        }
        remainder := mod(mul(dividend, ONE_WAD), divisor)
    }
}

// @dev overflows if sum would be greater than 2**256/10**18 (approximatly 10**59)
function unsafeAdd(FixedU18 addend1, FixedU18 addend2) pure returns (FixedU18 sum) {
    assembly ("memory-safe") {
        sum := add(addend1, addend2)
    }
}

// @dev underflows if subtrahend is greater than minuend
function unsafeSub(FixedU18 minuend, FixedU18 subtrahend) pure returns (FixedU18 difference) {
    assembly ("memory-safe") {
        difference := sub(minuend, subtrahend)
    }
}

// @dev overflows if product would be greater than 2**256/10**18 (approximatly 10**59)
function unsafeMulDown(FixedU18 factor1, FixedU18 factor2) pure returns (FixedU18 product) {
    assembly ("memory-safe") {
        product := div(mul(factor1, factor2), ONE_WAD)
    }
}

function equals(FixedU18 a, FixedU18 b) pure returns (bool) {
    return FixedU18.unwrap(a) == FixedU18.unwrap(b);
}

function greaterThan(FixedU18 a, FixedU18 b) pure returns (bool) {
    return FixedU18.unwrap(a) > FixedU18.unwrap(b);
}

function lessThan(FixedU18 a, FixedU18 b) pure returns (bool) {
    return FixedU18.unwrap(a) < FixedU18.unwrap(b);
}

function greaterThanOrEqualTo(FixedU18 a, FixedU18 b) pure returns (bool) {
    return FixedU18.unwrap(a) >= FixedU18.unwrap(b);
}

function lessThanOrEqualTo(FixedU18 a, FixedU18 b) pure returns (bool) {
    return FixedU18.unwrap(a) <= FixedU18.unwrap(b);
}

library FixedU18Library {
    // @dev overflows if product would be greater than 2**256/10**18 (approximatly 10**59)
    function mul(FixedU18 factor1, uint256 factor2) internal pure returns (FixedU18 product) {
        assembly ("memory-safe") {
            product := mul(factor1, factor2)
        }
    }

    function exp(FixedU18 base, uint64 exponent) internal pure returns (FixedU18 power) {
        assembly ("memory-safe") {
            power := ONE_WAD
            if exponent {
                for {} gt(exponent, 1) {} {
                    if and(1, exponent) {
                        power := div(mul(base, power), ONE_WAD)
                    }
                    base := div(mul(base, base), ONE_WAD)
                    exponent := shr(1, exponent)
                }
                power := div(mul(base, power), ONE_WAD)
            }
        }
    }
}
