//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        await AnisetteServersManager.shared.migrateToMacServerIfNeeded()

        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let entries: [(item: AnisetteServerItem, url: URL)] = await AnisetteServersManager.shared.loadLocalServers()
            .filter { !$0.isHidden }
            .compactMap { item in URL(string: item.address).map { (item: item, url: $0) } }
        guard !entries.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = entries.firstIndex(where: { $0.url.absoluteString == lastServer }) ?? 0
        let selected = entries[startIndex]

        // Rotating into a server of a different kind (legacy/Windows vs Mac) yields anisette data
        // that Apple rejects at sign-in (-80046), so only fail over to servers of the same kind.
        var candidates = [selected]
        if !UserDefaults.standard.disableAnisetteRotation {
            let rotated = entries[(startIndex + 1)...] + entries[..<startIndex]
            candidates += rotated.filter { selected.item.kind == nil || $0.item.kind == selected.item.kind }
        }

        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            debugLog("[AnisetteProvider] Attempting server [\(index + 1)/\(candidates.count)]: \(candidate.url.absoluteString)")
            do {
                return try await fetchRemote(from: candidate.url, handler: handler)
            } catch {
                lastError = error
                debugLog("[AnisetteProvider] Server '\(candidate.url.absoluteString)' failed: \(error.localizedDescription)")
            }
        }
        throw lastError ?? AnisetteError.allServersFailed
    }

    private static func fetchRemote(from server: URL, handler: AnisetteServerHandler?) async throws -> ALTAnisetteData {
        let provider = SideSign.AnisetteDataManager.shared
        let source = server.absoluteString

        // An adi.pb provisioned against one server's device identity is not valid for another.
        let blobSource = UserDefaults.standard.anisetteAdiBlobSource
        let existingBlob = blobSource == nil || blobSource == source
            ? AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
            : nil
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()

        // Apple validates that X-Mme-Client-Info matches the device the server provisions as,
        // so the server-reported identity takes precedence over the local defaults/overrides.
        var headers = await AnisetteConfigManager.shared.makeRequestHeaders()
        if let serverInfo = await AnisetteServersManager.shared.clientInfo(for: server) {
            headers.clientInfo = serverInfo.clientInfo
            headers.userAgent = serverInfo.userAgent
        }

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: [server],
            startIndex: 0,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            onError: { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
            }
        )

        if let freshBlob = newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
            UserDefaults.standard.anisetteAdiBlobSource = source
        }

        return anisetteData
    }
}
