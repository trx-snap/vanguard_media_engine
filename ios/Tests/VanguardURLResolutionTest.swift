// VanguardURLResolutionTest.swift
// Phase 4 Remote URL Support — Unit tests for URL.resolveVanguardPath
//
// Tests URL construction only — no network requests, no AVAsset playback.
// All assertions are deterministic and run fully offline.

import XCTest
@testable import vanguard_media_engine

final class VanguardURLResolutionTest: XCTestCase {

    // MARK: - Local file path

    func testLocalAbsolutePathIsFileURL() {
        let path = "/var/mobile/Containers/Data/Application/ABC/Documents/clip.mp4"
        let url = URL.resolveVanguardPath(path)
        XCTAssertNotNil(url, "Local absolute path must produce a non-nil URL")
        XCTAssertTrue(url!.isFileURL, "Local absolute path must resolve to a file URL")
        XCTAssertEqual(url!.path, path, "Resolved path must match the input")
    }

    // MARK: - file:// URL string

    func testFileSchemeStringIsFileURL() {
        let path = "file:///var/mobile/Containers/Data/Application/ABC/Documents/clip.mp4"
        let url = URL.resolveVanguardPath(path)
        XCTAssertNotNil(url, "file:// string must produce a non-nil URL")
        XCTAssertTrue(url!.isFileURL, "file:// string must resolve to a file URL")
        XCTAssertEqual(url!.scheme, "file")
    }

    // MARK: - https:// remote URL

    func testHTTPSRemoteURLIsNotFileURL() {
        let path = "https://example.com/video.mp4"
        let url = URL.resolveVanguardPath(path)
        XCTAssertNotNil(url, "https:// string must produce a non-nil URL")
        XCTAssertFalse(url!.isFileURL, "https:// string must NOT resolve to a file URL")
        XCTAssertEqual(url!.scheme, "https")
        XCTAssertEqual(url!.host, "example.com")
    }

    // MARK: - http:// remote URL

    func testHTTPRemoteURLIsNotFileURL() {
        let path = "http://example.com/video.mp4"
        let url = URL.resolveVanguardPath(path)
        XCTAssertNotNil(url, "http:// string must produce a non-nil URL")
        XCTAssertFalse(url!.isFileURL, "http:// string must NOT resolve to a file URL")
        XCTAssertEqual(url!.scheme, "http")
        XCTAssertEqual(url!.host, "example.com")
    }

    // MARK: - Empty / whitespace-only input

    func testEmptyStringReturnsNil() {
        XCTAssertNil(URL.resolveVanguardPath(""),
                     "Empty string must return nil")
    }

    func testWhitespaceOnlyStringReturnsNil() {
        XCTAssertNil(URL.resolveVanguardPath("   "),
                     "Whitespace-only string must return nil")
    }
}
