import XCTest
@testable import PaddockCore

final class EnvWiringTests: XCTestCase {
    // MARK: - Merge

    func testAKeyInPlaceIsUpdatedAndTheRestOfTheFileIsUntouched() {
        let result = EnvWiring.merge(existing: "# App settings\nAPP_KEY=base64:abc\nDB_HOST=old\n# tail\n",
                                     service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(result.text, "# App settings\nAPP_KEY=base64:abc\nDB_HOST=127.0.0.1\n# tail\n")
        XCTAssertEqual(result.settings, ["DB_HOST"])
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, ["DB_HOST"])
    }

    func testAKeyTheFileLacksIsAppendedAtTheEndInServiceOrder() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop\n",
                                     service: ["REDIS_HOST=127.0.0.1", "REDIS_PORT=6379"])
        XCTAssertEqual(result.text, "APP_NAME=shop\nREDIS_HOST=127.0.0.1\nREDIS_PORT=6379\n")
        XCTAssertEqual(result.settings, ["REDIS_HOST", "REDIS_PORT"])
        XCTAssertEqual(result.added, ["REDIS_HOST", "REDIS_PORT"])
        XCTAssertEqual(result.updated, [])
    }

    func testAFileWithoutAFinalNewlineGetsOneOnlyBeforeTheFirstAppendedLine() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop",
                                     service: ["DB_HOST=127.0.0.1", "DB_PORT=5432"])
        XCTAssertEqual(result.text, "APP_NAME=shop\nDB_HOST=127.0.0.1\nDB_PORT=5432")
        XCTAssertEqual(result.added, ["DB_HOST", "DB_PORT"])
    }

    func testEveryCopyOfADuplicatedKeyIsUpdated() {
        let result = EnvWiring.merge(existing: "DB_HOST=one\nDB_HOST=two\n", service: ["DB_HOST=three"])
        XCTAssertEqual(result.text, "DB_HOST=three\nDB_HOST=three\n")
        XCTAssertEqual(result.updated, ["DB_HOST"])
        XCTAssertEqual(result.added, [])
    }

    func testAnExportLineIsReplacedByThePlainSetting() {
        let result = EnvWiring.merge(existing: "export DB_HOST=old\r\n", service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(result.text, "DB_HOST=127.0.0.1\r\n")
        XCTAssertEqual(result.updated, ["DB_HOST"])
    }

    func testACRLFFileAppendsCRLFLines() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop\r\n",
                                     service: ["DB_HOST=127.0.0.1", "DB_PORT=5432"])
        XCTAssertEqual(result.text, "APP_NAME=shop\r\nDB_HOST=127.0.0.1\r\nDB_PORT=5432\r\n")
    }

    func testAMixedFileAppendsLF() {
        let result = EnvWiring.merge(existing: "A=1\r\nB=2\n", service: ["C=3"])
        XCTAssertEqual(result.text, "A=1\r\nB=2\nC=3\n")
    }

    func testAValueMayHoldAnEqualsSignOrBeEmpty() {
        let result = EnvWiring.merge(existing: "", service: ["S3_URL=http://localhost:8333/?x=1", "S3_KEY="])
        XCTAssertEqual(result.text, "S3_URL=http://localhost:8333/?x=1\nS3_KEY=")
        XCTAssertEqual(result.settings, ["S3_URL", "S3_KEY"])
        XCTAssertEqual(result.added, ["S3_URL", "S3_KEY"])
    }

    func testServiceCommentsBlankLinesAndNonSettingsAreIgnored() {
        let result = EnvWiring.merge(existing: "APP_NAME=shop\n",
                                     service: ["# Redis", "", "REDIS_HOST=127.0.0.1", "not a setting", "BAD-KEY=x"])
        XCTAssertEqual(result.text, "APP_NAME=shop\nREDIS_HOST=127.0.0.1\n")
        XCTAssertEqual(result.settings, ["REDIS_HOST"])
    }

    func testARepeatedServiceKeyKeepsItsFirstPositionAndItsLastValue() {
        let result = EnvWiring.merge(existing: "", service: ["DB_HOST=old", "DB_PORT=5432", "DB_HOST=new"])
        XCTAssertEqual(result.text, "DB_HOST=new\nDB_PORT=5432")
        XCTAssertEqual(result.settings, ["DB_HOST", "DB_PORT"])
        XCTAssertEqual(result.added, ["DB_HOST", "DB_PORT"])
    }

    func testAMalformedFileLineIsLeftWhereItIsAndTheKeyIsAppended() {
        let result = EnvWiring.merge(existing: "  DB_HOST = old\n\n# c\n", service: ["DB_HOST=new"])
        XCTAssertEqual(result.text, "  DB_HOST = old\n\n# c\nDB_HOST=new\n")
        XCTAssertEqual(result.added, ["DB_HOST"])
    }

    func testAnExistingKeyWithAnEmptyValueIsUpdated() {
        let result = EnvWiring.merge(existing: "S3_KEY=\n", service: ["S3_KEY=abc"])
        XCTAssertEqual(result.text, "S3_KEY=abc\n")
        XCTAssertEqual(result.updated, ["S3_KEY"])
    }

    func testChangesAreListedInTheServicesOrderNotTheFiles() {
        let result = EnvWiring.merge(existing: "B=1\nA=1\n", service: ["A=2", "B=2"])
        XCTAssertEqual(result.text, "B=2\nA=2\n")
        XCTAssertEqual(result.updated, ["A", "B"])
    }

    func testAFileThatAlreadyHasEveryValueChangesNothing() {
        let result = EnvWiring.merge(existing: "DB_HOST=127.0.0.1\n", service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(result.text, "DB_HOST=127.0.0.1\n")
        XCTAssertEqual(result.settings, ["DB_HOST"])
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, [])
    }

    func testAServiceWithNoSettingsChangesNothing() {
        let result = EnvWiring.merge(existing: "# only comments\n", service: ["# nothing", ""])
        XCTAssertEqual(result.text, "# only comments\n")
        XCTAssertEqual(result.settings, [])
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.updated, [])
    }

    // MARK: - Sentences

    func testTheResultSentenceNamesAddedAndUpdatedKeysOnly() {
        let result = EnvWiring.merge(existing: "DB_HOST=old\n",
                                     service: ["DB_HOST=new", "REDIS_HOST=127.0.0.1"])
        XCTAssertEqual(Messages.envWiringResult(result, service: "Mail", host: "shop.test"),
                       "Wired Mail into shop.test's .env: added REDIS_HOST; updated DB_HOST.")
    }

    func testOnlyAddedOrOnlyUpdatedListsItsOnePart() {
        let added = EnvWiring.merge(existing: "", service: ["REDIS_HOST=127.0.0.1"])
        XCTAssertEqual(Messages.envWiringResult(added, service: "Mail", host: "shop.test"),
                       "Wired Mail into shop.test's .env: added REDIS_HOST.")
        let updated = EnvWiring.merge(existing: "DB_HOST=old\n", service: ["DB_HOST=new"])
        XCTAssertEqual(Messages.envWiringResult(updated, service: "Mail", host: "shop.test"),
                       "Wired Mail into shop.test's .env: updated DB_HOST.")
    }

    func testNothingToDoSaysTheFileIsAlreadyWired() {
        let result = EnvWiring.merge(existing: "DB_HOST=127.0.0.1\n", service: ["DB_HOST=127.0.0.1"])
        XCTAssertEqual(Messages.envWiringResult(result, service: "Mail", host: "shop.test"),
                       "shop.test's .env already has every line from Mail.")
    }

    func testAServiceWithNoSettingsSaysSo() {
        let result = EnvWiring.merge(existing: "A=1\n", service: ["# nothing"])
        XCTAssertEqual(Messages.envWiringResult(result, service: "Mail", host: "shop.test"),
                       "Mail has no .env lines to wire.")
    }
}
