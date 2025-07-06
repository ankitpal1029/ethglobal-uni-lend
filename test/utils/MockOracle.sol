// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IChainLink {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);

    function setPrice(int256) external;
}

library Common {
    // @notice The asset struct to hold the address of an asset and amount
    struct Asset {
        address assetAddress;
        uint256 amount;
    }

    struct AddressAndWeight {
        address addr;
        uint64 weight;
    }
}

interface IFeeManager {
    /**
     * @return fee, reward, totalDiscount
     */
    function getFeeAndReward(address subscriber, bytes memory unverifiedReport, address quoteAddress)
        external
        returns (Common.Asset memory, Common.Asset memory, uint256);

    function i_linkAddress() external view returns (address);

    function i_nativeAddress() external view returns (address);

    function i_rewardManager() external view returns (address);
}

interface IVerifierFeeManager is IERC165 {
    /**
     * @notice Handles fees for a report from the subscriber and manages rewards
     * @param payload report to process the fee for
     * @param parameterPayload fee payload
     * @param subscriber address of the fee will be applied
     */
    function processFee(bytes calldata payload, bytes calldata parameterPayload, address subscriber) external payable;

    /**
     * @notice Processes the fees for each report in the payload, billing the subscriber and paying the reward manager
     * @param payloads reports to process
     * @param parameterPayload fee payload
     * @param subscriber address of the user to process fee for
     */
    function processFeeBulk(bytes[] calldata payloads, bytes calldata parameterPayload, address subscriber)
        external
        payable;

    /**
     * @notice Sets the fee recipients according to the fee manager
     * @param configDigest digest of the configuration
     * @param rewardRecipientAndWeights the address and weights of all the recipients to receive rewards
     */
    function setFeeRecipients(bytes32 configDigest, Common.AddressAndWeight[] calldata rewardRecipientAndWeights)
        external;
}

struct ReportV3 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 price;
    int192 bid;
    int192 ask;
}

interface IVerifierProxy {
    /**
     * @notice Route a report to the correct verifier and (optionally) bill fees.
     * @param payload           Full report payload (header + signed report).
     * @param parameterPayload  ABI-encoded fee metadata.
     */
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);

    function verifyBulk(bytes[] calldata payloads, bytes calldata parameterPayload)
        external
        payable
        returns (bytes[] memory verifiedReports);

    function s_feeManager() external view returns (IVerifierFeeManager);
}

contract MockChainLink is IChainLink {
    error InvalidReportVersion(uint16 version);

    int256 price = 100000000;
    IVerifierProxy i_verifierProxy = IVerifierProxy(0x6733e9106094b0C794e8E0297c96611fF60460Bf);

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, 0, 0);
    }

    function decimals() external view returns (uint8) {
        return (8);
    }

    function setPrice(int256 newPrice) public {
        price = newPrice;
    }

    function verifyReport(bytes memory unverifiedReport) external {
        // ─── 1. & 2. Extract reportData and schema version ──
        (, bytes memory reportData) = abi.decode(unverifiedReport, (bytes32[3], bytes));

        uint16 reportVersion = (uint16(uint8(reportData[0])) << 8) | uint16(uint8(reportData[1]));
        if (reportVersion != 3 && reportVersion != 4) {
            revert InvalidReportVersion(reportVersion);
        }

        // ─── 3. Fee handling ──
        IFeeManager feeManager = IFeeManager(address(i_verifierProxy.s_feeManager()));

        bytes memory parameterPayload;
        if (address(feeManager) != address(0)) {
            // FeeManager exists — always quote & approve
            address feeToken = feeManager.i_linkAddress();

            (Common.Asset memory fee,,) = feeManager.getFeeAndReward(address(this), reportData, feeToken);

            IERC20(feeToken).approve(feeManager.i_rewardManager(), fee.amount);
            parameterPayload = abi.encode(feeToken);
        } else {
            // No FeeManager deployed on this chain
            parameterPayload = bytes("");
        }

        // ─── 4. Verify through the proxy ──
        bytes memory verified = i_verifierProxy.verify(unverifiedReport, parameterPayload);

        // ─── 5. Decode & store price ──
        if (reportVersion == 3) {
            int192 _price = abi.decode(verified, (ReportV3)).price;
            price = int256(_price);
            // emit DecodedPrice(price);
        } else {
            revert InvalidReportVersion(reportVersion);
        }
    }
}
