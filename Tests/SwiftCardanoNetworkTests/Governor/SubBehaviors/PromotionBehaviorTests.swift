import Testing

@testable import SwiftCardanoNetwork

// MARK: - Helpers

private func pid(_ i: Int) -> PeerID {
    PeerID(host: "10.0.0.\(i)", port: 3001)
}

private func initializedState() -> PeerState {
    var s = PeerState()
    s.connection = .initialized
    return s
}

// MARK: - Defaults & counts

@Suite("PromotionConfig defaults") struct PromotionConfigDefaultsTests {

    @Test func matchesPallasDefaults() {
        let c = PromotionConfig()
        #expect(c.maxPeers == 100)
        #expect(c.maxWarmPeers == 50)
        #expect(c.maxHotPeers == 10)
        #expect(c.maxErrorCount == 1)
    }
}

@Suite("PromotionBehavior — counts & deficit") struct PromotionCountsTests {

    @Test func startsEmpty() {
        let p = PromotionBehavior()
        #expect(p.coldPeers.isEmpty)
        #expect(p.warmPeers.isEmpty)
        #expect(p.hotPeers.isEmpty)
        #expect(p.bannedPeers.isEmpty)
        #expect(p.totalPeers == 0)
        #expect(p.peerDeficit == 100)
    }

    @Test func peerDeficitTracksTotal() {
        var p = PromotionBehavior(config: PromotionConfig(maxPeers: 10))
        for i in 1...3 {
            var s = PeerState()
            p.onPeerDiscovered(pid(i), &s)
        }
        #expect(p.peerDeficit == 7)
        #expect(p.totalPeers == 3)
    }

    @Test func bannedPeersDoNotCountInTotal() {
        var p = PromotionBehavior(config: PromotionConfig(maxPeers: 10))
        var s = PeerState()
        p.onPeerDiscovered(pid(1), &s)
        p.banPeer(pid(1), &s)
        #expect(p.totalPeers == 0)
        #expect(p.bannedPeers.count == 1)
        #expect(p.peerDeficit == 10)
    }
}

// MARK: - Discovery → cold

@Suite("PromotionBehavior — onPeerDiscovered") struct PromotionDiscoveryTests {

    @Test func placesIntoCold() {
        var p = PromotionBehavior()
        var s = PeerState()
        p.onPeerDiscovered(pid(1), &s)
        #expect(p.coldPeers.contains(pid(1)))
        #expect(s.promotion == .cold)
    }

    @Test func capsAtMaxPeers() {
        var p = PromotionBehavior(config: PromotionConfig(maxPeers: 3, maxWarmPeers: 0, maxHotPeers: 0))
        for i in 1...5 {
            var s = PeerState()
            p.onPeerDiscovered(pid(i), &s)
        }
        // 3 cap, none promoted (warm cap is 0)
        #expect(p.totalPeers <= 3)
    }

    @Test func bannedPeerStaysBannedOnRediscovery() {
        var p = PromotionBehavior()
        var s = PeerState()
        p.banPeer(pid(1), &s)
        p.onPeerDiscovered(pid(1), &s)
        #expect(p.bannedPeers.contains(pid(1)))
        #expect(!p.coldPeers.contains(pid(1)))
        #expect(s.promotion == .banned)
    }

    @Test func discoveredVisitorHookCallsOnPeerDiscovered() {
        var p = PromotionBehavior()
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        #expect(p.coldPeers.contains(pid(1)))
        #expect(s.promotion == .cold)
    }
}

// MARK: - Promotions cold→warm and warm→hot

@Suite("PromotionBehavior — categorize promotions") struct PromotionCategorizeTests {

    @Test func housekeepingPromotesColdToWarm() {
        var p = PromotionBehavior(config: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 0))
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        #expect(p.coldPeers.contains(pid(1)))

        p.housekeeping(pid(1), &s, &q)
        #expect(p.warmPeers.contains(pid(1)))
        #expect(!p.coldPeers.contains(pid(1)))
        #expect(s.promotion == .warm)
    }

    @Test func housekeepingPromotesWarmToHotWhenInitialized() {
        var p = PromotionBehavior(config: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5))
        var s = initializedState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.housekeeping(pid(1), &s, &q)  // cold → warm
        p.housekeeping(pid(1), &s, &q)  // warm → hot
        #expect(p.hotPeers.contains(pid(1)))
        #expect(!p.warmPeers.contains(pid(1)))
        #expect(s.promotion == .hot)
    }

    @Test func warmToHotRequiresInitialized() {
        var p = PromotionBehavior(config: PromotionConfig(maxWarmPeers: 5, maxHotPeers: 5))
        var s = PeerState()              // not initialized
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.housekeeping(pid(1), &s, &q)   // cold → warm
        p.housekeeping(pid(1), &s, &q)   // should NOT go warm → hot
        #expect(p.warmPeers.contains(pid(1)))
        #expect(!p.hotPeers.contains(pid(1)))
    }

    @Test func maxWarmPeersRespected() {
        var p = PromotionBehavior(config: PromotionConfig(maxPeers: 100, maxWarmPeers: 2, maxHotPeers: 10, maxErrorCount: 5))
        for i in 1...5 {
            var s = PeerState()
            p.onPeerDiscovered(pid(i), &s)
        }
        for i in 1...5 {
            var s = PeerState()
            s.promotion = .cold
            var q = OutboundQueue()
            p.housekeeping(pid(i), &s, &q)
        }
        #expect(p.warmPeers.count <= 2)
    }

    @Test func maxHotPeersRespected() {
        var p = PromotionBehavior(config: PromotionConfig(maxPeers: 100, maxWarmPeers: 10, maxHotPeers: 1, maxErrorCount: 5))
        // Seed 3 warm peers manually via discovery + housekeeping
        for i in 1...3 {
            var s = PeerState()
            var q = OutboundQueue()
            p.discovered(pid(i), &s, &q)
            p.housekeeping(pid(i), &s, &q)   // cold → warm
        }
        #expect(p.warmPeers.count == 3)

        // Drive each peer's housekeeping with initialized state — at most one
        // should be promoted to hot.
        for i in 1...3 {
            var s = initializedState()
            s.promotion = .warm
            var q = OutboundQueue()
            p.housekeeping(pid(i), &s, &q)
        }
        #expect(p.hotPeers.count <= 1)
    }

    @Test func inboundMessageTriggersCategorize() {
        var p = PromotionBehavior(config: PromotionConfig(maxWarmPeers: 5))
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.inboundMessage(pid(1), &s, &q)
        #expect(p.warmPeers.contains(pid(1)))
    }
}

// MARK: - Bans

@Suite("PromotionBehavior — bans") struct PromotionBanTests {

    @Test func banRemovesFromAllSets() {
        var p = PromotionBehavior()
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.housekeeping(pid(1), &s, &q)  // → warm
        #expect(p.warmPeers.contains(pid(1)))

        p.banPeer(pid(1), &s)
        #expect(p.bannedPeers.contains(pid(1)))
        #expect(!p.warmPeers.contains(pid(1)))
        #expect(!p.coldPeers.contains(pid(1)))
        #expect(!p.hotPeers.contains(pid(1)))
        #expect(s.promotion == .banned)
    }

    @Test func violationTriggersBan() {
        var p = PromotionBehavior()
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.housekeeping(pid(1), &s, &q)   // → warm
        s.violation = true
        p.housekeeping(pid(1), &s, &q)
        #expect(p.bannedPeers.contains(pid(1)))
        #expect(s.promotion == .banned)
    }

    @Test func violationEmitsBannedEvent() {
        var p = PromotionBehavior()
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.housekeeping(pid(1), &s, &q)
        q = OutboundQueue()
        s.violation = true
        p.housekeeping(pid(1), &s, &q)

        let events = q.items.compactMap { item -> GovernorEvent? in
            if case .event(let e) = item { return e } else { return nil }
        }
        #expect(events.count == 1)
        guard case .peerBanned(let bannedPid, let reason) = events[0] else {
            Issue.record("expected .peerBanned"); return
        }
        #expect(bannedPid == pid(1))
        #expect(reason == .violation)
    }

    @Test func errorCountAtThresholdDoesNotBan() {
        // Threshold check is strict (>) — errorCount == limit is OK.
        var p = PromotionBehavior(config: PromotionConfig(maxErrorCount: 1))
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        s.errorCount = 1
        p.housekeeping(pid(1), &s, &q)
        #expect(!p.bannedPeers.contains(pid(1)))
    }

    @Test func errorCountAboveThresholdBans() {
        var p = PromotionBehavior(config: PromotionConfig(maxErrorCount: 1))
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        s.errorCount = 2
        p.housekeeping(pid(1), &s, &q)
        #expect(p.bannedPeers.contains(pid(1)))
    }

    @Test func errorThresholdEventCarriesCounts() {
        var p = PromotionBehavior(config: PromotionConfig(maxErrorCount: 3))
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        q = OutboundQueue()
        s.errorCount = 7
        p.housekeeping(pid(1), &s, &q)

        let events = q.items.compactMap { item -> GovernorEvent? in
            if case .event(let e) = item { return e } else { return nil }
        }
        guard case .peerBanned(_, let reason) = events.first else {
            Issue.record("expected .peerBanned"); return
        }
        #expect(reason == .errorThreshold(observed: 7, limit: 3))
    }

    @Test func banDoesNotEmitTwiceForAlreadyBannedPeer() {
        var p = PromotionBehavior()
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        s.violation = true
        p.housekeeping(pid(1), &s, &q)
        let firstCount = q.items.count
        // Re-tick: violation is still set, but peer is already banned — no second event.
        p.housekeeping(pid(1), &s, &q)
        #expect(q.items.count == firstCount)
    }
}

// MARK: - Demotion

@Suite("PromotionBehavior — demotion") struct PromotionDemoteTests {

    @Test func demoteWarmReturnsToCold() {
        var p = PromotionBehavior()
        var s = PeerState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.housekeeping(pid(1), &s, &q)   // → warm
        p.demotePeer(pid(1), &s)
        #expect(p.coldPeers.contains(pid(1)))
        #expect(!p.warmPeers.contains(pid(1)))
        #expect(s.promotion == .cold)
    }

    @Test func demoteHotReturnsToCold() {
        var p = PromotionBehavior(config: PromotionConfig(maxHotPeers: 5))
        var s = initializedState()
        var q = OutboundQueue()
        p.discovered(pid(1), &s, &q)
        p.housekeeping(pid(1), &s, &q)   // cold → warm
        p.housekeeping(pid(1), &s, &q)   // warm → hot
        p.demotePeer(pid(1), &s)
        #expect(p.coldPeers.contains(pid(1)))
        #expect(!p.hotPeers.contains(pid(1)))
        #expect(s.promotion == .cold)
    }

    @Test func demoteBannedIsNoop() {
        var p = PromotionBehavior()
        var s = PeerState()
        p.banPeer(pid(1), &s)
        p.demotePeer(pid(1), &s)
        #expect(p.bannedPeers.contains(pid(1)))
        #expect(!p.coldPeers.contains(pid(1)))
    }
}
