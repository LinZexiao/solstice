// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {FVMAddress} from "fvm-solidity/FVMAddress.sol";

import {MockRewardWireTest} from "./MockRewardWireTest.sol";
import {WeightRecord, WeightRecordUpdate, Share, PendingOp} from "../../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";
import {FVMRewards} from "../../src/lib/FVMRewards.sol";

/// @dev Tests to match with Rust `fil_actor_reward` tests/types_test.rs `mod serialization`, whose
/// vectors these hex literals are copied from. Go's mirror is
/// go-state-types/builtin/*/reward.
///
/// FVMRewards is the SWA's and SRA's production caller, and the mock in this repo decodes with the
/// mirror image of its encoder, so the two agree with each other whatever they emit. Only these
/// vectors, which come from f02 itself, can tell either of them apart from the chain.
///
/// Some vectors pin a shape f02 will refuse on inspection (an empty weight batch, for one). They
/// fix the encoding, not the admissibility.
contract FVMRewardWireTest is MockRewardWireTest {
    function _record(int256 vStart, int256 slope, uint64 tStart, int256 floor, int256 cap)
        internal
        pure
        returns (WeightRecord memory)
    {
        return WeightRecord({vStart: vStart, slope: slope, tStart: Epoch.wrap(tStart), floor: floor, cap: cap});
    }

    function _sent() internal view returns (bytes memory) {
        return rewardActor().mockLastParams();
    }

    /// @dev `vm.expectRevert` cannot see a revert that happens after `_invoke`'s delegatecall,
    /// since that delegatecall runs inlined in this contract's own frame rather than behind a
    /// real CALL boundary. Routing through an external self-call gives `expectRevert` one to catch.
    function _externalClaim(uint64 id, address[] memory wallets)
        external
        returns (int256 exitCode, uint256[] memory amounts)
    {
        return FVMRewards.tryClaim(id, wallets);
    }

    // [[
    //   [23,[23,-24,23,0,23]], [24,[24,-25,24,0,24]],
    //   [255,[255,-256,255,0,255]], [256,[256,-257,256,0,256]],
    //   [65535,[65535,-65536,65535,0,65535]], [65536,[65536,-65537,65536,0,65536]],
    //   [4294967295,[4294967295,-4294967296,4294967295,0,4294967295]],
    //   [4294967296,[4294967296,-4294967297,4294967296,0,4294967296]]
    // ]]
    function test_SetWeightRecords_WalksEveryIntegerWidth() public {
        uint64[8] memory v = [uint64(23), 24, 255, 256, 65_535, 65_536, 4_294_967_295, 4_294_967_296];
        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](8);
        for (uint256 i = 0; i < 8; i++) {
            updates[i] = WeightRecordUpdate({
                id: v[i],
                record: _record(int256(uint256(v[i])), -int256(uint256(v[i])) - 1, v[i], 0, int256(uint256(v[i])))
            });
        }

        FVMRewards.trySetWeightRecords(updates);
        assertEq(
            _sent(),
            hex"81888217851737170017821818851818381818180018188218ff8518ff38ff18ff0018ff"
            hex"8219010085190100390100190100001901008219ffff8519ffff39ffff19ffff0019ffff"
            hex"821a00010000851a000100003a000100001a00010000001a00010000"
            hex"821affffffff851affffffff3affffffff1affffffff001affffffff"
            hex"821b0000000100000000851b00000001000000003b0000000100000000" hex"1b0000000100000000001b0000000100000000"
        );
    }

    /// @dev Identical params, different dispatch. The two are separate calls because f02 will not
    /// let the discretionary path cancel what the gate produced.
    function test_StepWeightRecords_EncodesLikeSetWeightRecords() public {
        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](1);
        updates[0] = WeightRecordUpdate({id: 23, record: _record(23, -24, 23, 0, 23)});

        FVMRewards.trySetWeightRecords(updates);
        bytes memory set = _sent();
        FVMRewards.tryStepWeightRecords(updates);
        assertEq(_sent(), set);
    }

    // [[]] and one entry at the widest form. Step encodes identically to Set but is pinned
    // separately, so this table stands alone as a description of the method.
    function test_StepWeightRecords_EmptyAndBoundaryBatch() public {
        FVMRewards.tryStepWeightRecords(new WeightRecordUpdate[](0));
        assertEq(_sent(), hex"8180");

        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](1);
        updates[0] =
            WeightRecordUpdate({id: 4_294_967_296, record: _record(4_294_967_296, -4_294_967_297, 65_536, 256, 1e18)});
        FVMRewards.tryStepWeightRecords(updates);
        assertEq(
            _sent(),
            hex"8181821b0000000100000000851b00000001000000003b0000000100000000" hex"1a000100001901001b0de0b6b3a7640000"
        );
    }

    // [
    //   4294967296,[4294967296,-4294967296,65536,256,1000000000000000000],
    //   [byte[040a1111111111111111111111111111111111111111],
    //     [[byte[008080808010],1000000000000000000]]],65536
    // ]
    function test_RegisterStream_ExplicitCarriesWriterAndInitialMap() public {
        Share[] memory shares = new Share[](1);
        shares[0] = Share({wallet: FVMAddress.maskedAddress(4_294_967_296), share: FixedU18.wrap(1e18)});
        FVMRewards.tryRegisterStream(
            4_294_967_296,
            _record(4_294_967_296, -4_294_967_296, 65_536, 256, 1e18),
            0x1111111111111111111111111111111111111111,
            shares,
            65_536
        );
        assertEq(
            _sent(),
            hex"841b0000000100000000851b00000001000000003affffffff1a000100001901"
            hex"001b0de0b6b3a76400008256040a111111111111111111111111111111111111"
            hex"11118182460080808080101b0de0b6b3a76400001a00010000"
        );
    }

    // [24,[24,-24,256,0,65536],null,4294967296]
    function test_RegisterStream_ImplicitIsANullDistribution() public {
        FVMRewards.tryRegisterStream(24, _record(24, -24, 256, 0, 65_536), 4_294_967_296);
        assertEq(_sent(), hex"84181885181837190100001a00010000f61b0000000100000000");
    }

    // [24] and [256] -- a single-field parameter tuple is still an array.
    function test_RemoveStream_WrapsTheIdInAnArray() public {
        FVMRewards.tryRemoveStream(24);
        assertEq(_sent(), hex"811818");
        FVMRewards.tryRemoveStream(256);
        assertEq(_sent(), hex"81190100");
        FVMRewards.tryRemoveStream(65_536);
        assertEq(_sent(), hex"811a00010000");
        FVMRewards.tryRemoveStream(4_294_967_296);
        assertEq(_sent(), hex"811b0000000100000000");
    }

    // [24,byte[008080808010]] and [256,byte[040a1111...1111]] -- one writer in each address form.
    function test_SetDistribution_CarriesOnlyTheWriter() public {
        FVMRewards.trySetDistribution(24, FVMAddress.maskedAddress(4_294_967_296));
        assertEq(_sent(), hex"82181846008080808010");
        FVMRewards.trySetDistribution(256, 0x1111111111111111111111111111111111111111);
        assertEq(_sent(), hex"8219010056040a1111111111111111111111111111111111111111");
    }

    // [24,[]]
    function test_SetShares_EmptyMap() public {
        FVMRewards.trySetShares(24, new Share[](0));
        assertEq(_sent(), hex"82181880");
    }

    // [
    //   256,[[byte[0018],24],[byte[008002],256],
    //   [byte[00808004],65536],[byte[008080808010],4294967296]]
    // ]
    function test_SetShares_WalksEveryIntegerWidth() public {
        uint64[4] memory v = [uint64(24), 256, 65_536, 4_294_967_296];
        Share[] memory shares = new Share[](4);
        for (uint256 i = 0; i < 4; i++) {
            shares[i] = Share({wallet: FVMAddress.maskedAddress(v[i]), share: FixedU18.wrap(v[i])});
        }
        FVMRewards.trySetShares(256, shares);
        assertEq(
            _sent(),
            hex"821901008482420018181882430080021901008244008080041a00010000" hex"82460080808080101b0000000100000000"
        );
    }

    /// @dev The cap, and the only case where an array header needs two bytes.
    // [65536,64 * [byte[f01000..f01063],15625000000000000]]
    function test_SetShares_MaxRecipients() public {
        Share[] memory shares = new Share[](64);
        for (uint64 i = 0; i < 64; i++) {
            shares[i] = Share({wallet: FVMAddress.maskedAddress(1000 + i), share: FixedU18.wrap(1e18 / 64)});
        }
        FVMRewards.trySetShares(65_536, shares);
        assertEq(
            _sent(),
            hex"821a000100009840824300e8071b003782dace9d9000824300e9071b003782da"
            hex"ce9d9000824300ea071b003782dace9d9000824300eb071b003782dace9d9000"
            hex"824300ec071b003782dace9d9000824300ed071b003782dace9d9000824300ee"
            hex"071b003782dace9d9000824300ef071b003782dace9d9000824300f0071b0037"
            hex"82dace9d9000824300f1071b003782dace9d9000824300f2071b003782dace9d"
            hex"9000824300f3071b003782dace9d9000824300f4071b003782dace9d90008243"
            hex"00f5071b003782dace9d9000824300f6071b003782dace9d9000824300f7071b"
            hex"003782dace9d9000824300f8071b003782dace9d9000824300f9071b003782da"
            hex"ce9d9000824300fa071b003782dace9d9000824300fb071b003782dace9d9000"
            hex"824300fc071b003782dace9d9000824300fd071b003782dace9d9000824300fe"
            hex"071b003782dace9d9000824300ff071b003782dace9d900082430080081b0037"
            hex"82dace9d900082430081081b003782dace9d900082430082081b003782dace9d"
            hex"900082430083081b003782dace9d900082430084081b003782dace9d90008243"
            hex"0085081b003782dace9d900082430086081b003782dace9d900082430087081b"
            hex"003782dace9d900082430088081b003782dace9d900082430089081b003782da"
            hex"ce9d90008243008a081b003782dace9d90008243008b081b003782dace9d9000"
            hex"8243008c081b003782dace9d90008243008d081b003782dace9d90008243008e"
            hex"081b003782dace9d90008243008f081b003782dace9d900082430090081b0037"
            hex"82dace9d900082430091081b003782dace9d900082430092081b003782dace9d"
            hex"900082430093081b003782dace9d900082430094081b003782dace9d90008243"
            hex"0095081b003782dace9d900082430096081b003782dace9d900082430097081b"
            hex"003782dace9d900082430098081b003782dace9d900082430099081b003782da"
            hex"ce9d90008243009a081b003782dace9d90008243009b081b003782dace9d9000"
            hex"8243009c081b003782dace9d90008243009d081b003782dace9d90008243009e"
            hex"081b003782dace9d90008243009f081b003782dace9d9000824300a0081b0037"
            hex"82dace9d9000824300a1081b003782dace9d9000824300a2081b003782dace9d"
            hex"9000824300a3081b003782dace9d9000824300a4081b003782dace9d90008243"
            hex"00a5081b003782dace9d9000824300a6081b003782dace9d9000824300a7081b" hex"003782dace9d9000"
        );
    }

    /// @dev The one vector on the decode side. `_decodeAmounts` reads a Filecoin BigInt per wallet,
    /// where an empty byte string is zero and anything else is a sign byte then a big-endian
    /// magnitude, so the widths here are what that parser has to get right.
    // [[byte[],byte[0018],byte[000100],byte[00010000],byte[000100000000]]]
    function test_ClaimReturn_DecodesEveryAmountWidth() public {
        rewardActor().mockSetClaimReturn(hex"81854042001843000100440001000046000100000000");
        (int256 exitCode, uint256[] memory amounts) = FVMRewards.tryClaim(1, new address[](5));
        assertEq(exitCode, 0);
        assertEq(amounts.length, 5);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 24);
        assertEq(amounts[2], 256);
        assertEq(amounts[3], 65_536);
        assertEq(amounts[4], 4_294_967_296);
    }

    // [[]] -- a claim for nobody decodes to an empty array, not a revert.
    function test_ClaimReturn_Empty() public {
        rewardActor().mockSetClaimReturn(hex"8180");
        (int256 exitCode, uint256[] memory amounts) = FVMRewards.tryClaim(1, new address[](0));
        assertEq(exitCode, 0);
        assertEq(amounts.length, 0);
    }

    /// @dev No other Claim vector reaches `_readHead`'s one-byte-extension case (info == 24): the
    /// count header here must encode a count outside CBOR's 0-23 inline range, so decoding 24
    /// amounts is what forces it to fire. Distinct nonzero amounts also confirm decoding stays
    /// correctly positioned across all 24 entries, not just that it doesn't revert.
    // [1..24, each byte[00xx]]
    function test_ClaimReturn_CountNeedsExtendedHeader() public {
        rewardActor()
            .mockSetClaimReturn(
                hex"81981842000142000242000342000442000542000642000742000842000942000a42000b42000c42000d42000e42000f"
                hex"420010420011420012420013420014420015420016420017420018"
            );
        (int256 exitCode, uint256[] memory amounts) = FVMRewards.tryClaim(1, new address[](24));
        assertEq(exitCode, 0);
        assertEq(amounts.length, 24);
        for (uint256 i = 0; i < 24; i++) {
            assertEq(amounts[i], i + 1);
        }
    }

    /// @dev A lone sign byte with an empty magnitude, distinct from an empty byte string.
    // [[byte[00]]]
    function test_ClaimReturn_SignByteWithEmptyMagnitudeIsZero() public {
        rewardActor().mockSetClaimReturn(hex"81814100");
        (int256 exitCode, uint256[] memory amounts) = FVMRewards.tryClaim(1, new address[](1));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0);
    }

    /// @dev The widest magnitude `_readBigInt` accepts: 32 bytes, forcing its shift amount to zero.
    // [[byte[00,ff*32]]]
    function test_ClaimReturn_WidestMagnitude() public {
        rewardActor()
            .mockSetClaimReturn(hex"8181582100ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
        (int256 exitCode, uint256[] memory amounts) = FVMRewards.tryClaim(1, new address[](1));
        assertEq(exitCode, 0);
        assertEq(amounts[0], type(uint256).max);
    }

    /// @dev A nonzero sign byte, which `_readBigInt` rejects even though f02 never emits one.
    // [[byte[01,01]]]
    function test_ClaimReturn_NegativeSignByte_Reverts() public {
        rewardActor().mockSetClaimReturn(hex"8181420101");
        vm.expectRevert(bytes(""));
        this._externalClaim(1, new address[](1));
    }

    /// @dev One byte past `_readBigInt`'s 32-byte magnitude cap.
    // [[byte[00,00*33]]]
    function test_ClaimReturn_OversizedMagnitude_Reverts() public {
        rewardActor()
            .mockSetClaimReturn(hex"8181582200000000000000000000000000000000000000000000000000000000000000000000");
        vm.expectRevert(bytes(""));
        this._externalClaim(1, new address[](1));
    }

    // [null,op] for the two schedule-wide weight slots, [id,op] for everything per stream.
    function test_CancelPending_NullIdAddressesTheWeightSlot() public {
        FVMRewards.tryCancelPendingWeight(PendingOp.SET_WEIGHT);
        assertEq(_sent(), hex"82f600");
        FVMRewards.tryCancelPending(24, PendingOp.REGISTER);
        assertEq(_sent(), hex"82181802");
        FVMRewards.tryCancelPending(256, PendingOp.REMOVE);
        assertEq(_sent(), hex"8219010003");
        FVMRewards.tryCancelPendingWeight(PendingOp.STEP_WEIGHT);
        assertEq(_sent(), hex"82f601");
        FVMRewards.tryCancelPending(65_536, PendingOp.SET_DISTRIBUTION);
        assertEq(_sent(), hex"821a0001000004");
    }

    // [4294967296,[]]
    function test_Claim_EmptyBatch() public {
        FVMRewards.tryClaim(4_294_967_296, new address[](0));
        assertEq(_sent(), hex"821b000000010000000080");
    }

    /// @dev The two address forms in one batch. A masked ID must not be emitted as f410: that
    /// names a delegated address nobody created, so it resolves nowhere and f02 rejects the call.
    /// f099, the burn actor the freeze rule pays into, is reachable only through the first form.
    // [65536,[byte[008080808010],byte[040a1111111111111111111111111111111111111111]]]
    function test_Claim_EncodesBothAddressForms() public {
        address[] memory wallets = new address[](2);
        wallets[0] = FVMAddress.maskedAddress(4_294_967_296);
        wallets[1] = 0x1111111111111111111111111111111111111111;
        FVMRewards.tryClaim(65_536, wallets);
        assertEq(_sent(), hex"821a000100008246008080808010" hex"56040a1111111111111111111111111111111111111111");
    }
}
