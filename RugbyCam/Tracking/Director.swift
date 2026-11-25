import Foundation

struct DirectorParams {
    var ballHold = 1.5            // keep aiming at the last ball position this long
    var ballBias = 0.35           // 0 = centre of the players, 1 = the ball
    var ballBlendTime = 0.4       // seconds to fade the ball's influence in and out
    var fillX = 0.55              // the action should fill this share of the width
    var fillY = 0.60
    var safeMargin = 0.06         // keep the action this far from the frame edge
    var minBoxW = 0.06
    var minBoxH = 0.10
    var trimFraction = 0.10       // ignore the outermost players on each side
    var trimMinPlayers = 5
    var playersHold = 0.6         // keep the last player box when one pass finds nobody
    var centerTau = 0.25          // smoothing of where the players are (seconds)
    var sizeTau = 0.6             // smoothing of how spread out they are (seconds)
    var zoomTauIn = 2.0           // zooming in is slow
    var zoomTauOut = 0.7          // zooming out is quicker
    var zoomTauUrgent = 0.35      // the action is leaving the frame
    var zoomUrgency = 2.5
    var zoomMaxLogRate = 0.6      // natural-log units per second (about 0.87 doublings)
    var zoomDeadband = 0.08       // ignore zoom changes smaller than about 8 %
    var panGain = 2.2
    var tiltGain = 1.3
    var panIntegralGain = 1.0
    var integralLimit = 0.35
    var integralLeak = 3.0        // seconds
    var panDeadband = 0.04
    var tiltDeadband = 0.08
    var rateSlew = 3.0            // how fast the pan/tilt rate may change, per second
    var searchDelay = 2.5         // nothing seen for this long: zoom out to look for play
    var minPlayersForZoomIn = 3   // with fewer players in view, never zoom in
    var maxPlayerHeight = 0.40    // do not zoom in until players are taller than this
    var tiltEnabled = true
    var situationsEnabled = true  // use the game situations (scrum, kick, ...) for the framing
    var situationSettle = 0.5     // a new situation must last this long before the framing changes
    var kickHold = 2.5            // keep the wide kick framing this long
    var breakHold = 1.0
    var pileMaxPlayerHeight = 0.50
    var breakLead = 0.10          // leave this share of the frame free ahead of a runner
}

struct DirectorInput {
    var time: Double
    var ball: NPoint?             // confirmed ball position (tracked or predicted), if any
    var ballAge: Double           // seconds since the ball was last detected
    var players: [NBox]
    var zoom: Double              // zoom of the frame the detections came from
    var zoomMin: Double
    var zoomMax: Double
    var wideZoom: Double          // zoom factor of the 1x lens
    var mountActive: Bool
    var autoZoom: Bool
    var ballVelocity: NPoint? = nil   // frame widths (x) and heights (y) per second
    var learned: [String: LearnedFrame] = [:]
    var displayMultiplier = 1.0
}

enum DirectorState: String {
    case ball
    case ballHeld
    case players
    case searching
}

struct DirectorOutput {
    var panRate = 0.0             // -1...1, positive = turn right
    var tiltRate = 0.0            // -1...1, positive = tilt down
    var zoomTarget = 1.0
    var state = DirectorState.searching
    var actionBox: NBox?
    var lookAt: NPoint?
    var situation = PlaySituation.lost
    var features = FramingFeatures()
    var frame: NBox?              // the part of the current picture the zoom is heading for
}

/// Decides where the camera should point and how far it should zoom.
/// It follows the ball while the ball is confirmed, and the group of players
/// when it is not.
final class Director {
    var params = DirectorParams()

    private var lastTime: Double?
    private var zoomInitialised = false
    private var logZoom = 0.0
    private var panRate = 0.0
    private var tiltRate = 0.0
    private var panIntegral = 0.0
    private var lastActionTime = -1.0e9
    private var havePlayers = false
    private var lastPlayersTime = -1.0e9
    private var smCx = 0.5        // smoothed centre of the players
    private var smCy = 0.5
    private var smLeft = 0.1      // smoothed distances from that centre to the box edges
    private var smRight = 0.1
    private var smUp = 0.1
    private var smDown = 0.1
    private var playerCount = 0.0 // smoothed number of players in view
    private var playerHeight = 0.1
    private var ballWeight = 0.0
    private var lastBall: NPoint?

    // Game situation
    private var situation = PlaySituation.open
    private var candidate = PlaySituation.open
    private var candidateSince = -1.0e9
    private var situationSince = -1.0e9
    private var prevCx = 0.5
    private var prevCy = 0.5
    private var groupSpeed = 0.0
    private var smCluster: NBox?
    private var lastFeatures = FramingFeatures()

    func reset() {
        lastTime = nil
        zoomInitialised = false
        logZoom = 0.0
        panRate = 0.0
        tiltRate = 0.0
        panIntegral = 0.0
        lastActionTime = -1.0e9
        havePlayers = false
        lastPlayersTime = -1.0e9
        smCx = 0.5
        smCy = 0.5
        smLeft = 0.1
        smRight = 0.1
        smUp = 0.1
        smDown = 0.1
        playerCount = 0.0
        playerHeight = 0.1
        ballWeight = 0.0
        lastBall = nil
        situation = .open
        candidate = .open
        candidateSince = -1.0e9
        situationSince = -1.0e9
        groupSpeed = 0.0
        smCluster = nil
    }

    // MARK: - Game situation

    /// Guesses the situation from this look and keeps it steady: a new one must
    /// last `situationSettle` seconds, except a kick, which counts at once.
    private func updateSituation(_ i: DirectorInput, dt: Double) -> PlaySituation {
        let p = params
        // How fast the group moves (smoothed centre, so it is calm).
        if havePlayers {
            let dx = smCx - prevCx
            let dy = (smCy - prevCy) * FramingMath.heightOverWidth
            let speed = (dx * dx + dy * dy).squareRoot() / max(dt, 0.01)
            groupSpeed += (speed - groupSpeed) * (1.0 - exp(-dt / 0.5))
            prevCx = smCx
            prevCy = smCy
        }

        var features = FramingFeatures()
        features.players = i.players.count
        features.zoom = i.zoom * i.displayMultiplier
        features.groupSpeed = groupSpeed
        let cluster = FramingMath.compactCluster(i.players)
        features.compactShare = cluster.share
        features.lineRatio = FramingMath.lineRatio(i.players)
        features.spread = FramingMath.spread(i.players)
        let ballFresh = i.ball != nil && i.ballAge <= 0.3
        features.ballSeen = ballFresh
        if ballFresh, let v = i.ballVelocity {
            features.ballSpeedX = v.x
            features.ballSpeedY = v.y
        }
        lastFeatures = features

        if let box = cluster.box {
            if let old = smCluster {
                let b = 1.0 - exp(-dt / p.sizeTau)
                smCluster = NBox(x: old.x + (box.x - old.x) * b, y: old.y + (box.y - old.y) * b,
                                 w: old.w + (box.w - old.w) * b, h: old.h + (box.h - old.h) * b)
            } else {
                smCluster = box
            }
        }

        guard p.situationsEnabled else { return .open }

        // What this one look suggests.
        var now = PlaySituation.open
        let calm = groupSpeed < 0.08
        if !havePlayers && i.ball == nil {
            now = .lost
        } else if ballFresh && features.ballSpeedY < -0.5 && abs(features.ballSpeedY) > abs(features.ballSpeedX) * 0.6 {
            now = .kick
        } else if ballFresh && abs(features.ballSpeedX) > 0.30 {
            now = .breakaway
        } else if features.players >= 6 && cluster.share >= 0.5 && calm {
            now = .pile
        } else if features.players >= 6 && features.lineRatio >= 3.0 && calm {
            now = .lineout
        }

        // Keep the kick and the break framing a little while after the moment.
        if situation == .kick && i.time - situationSince < p.kickHold && now != .kick {
            return situation
        }
        if situation == .breakaway && i.time - situationSince < p.breakHold && now == .open {
            return situation
        }
        if now == .kick {
            if situation != .kick {
                situationSince = i.time
            }
            situation = .kick
            candidate = .kick
            return situation
        }
        if now != candidate {
            candidate = now
            candidateSince = i.time
        }
        if candidate != situation && i.time - candidateSince >= p.situationSettle {
            situation = candidate
            situationSince = i.time
        }
        return situation
    }

    /// The share of the frame the action should take, and the offset, for this situation:
    /// the built-in rule, moved towards what the person showed in their examples.
    private func framing(for situation: PlaySituation, learned: [String: LearnedFrame]) -> (fill: Double, offset: Double) {
        var fill = FramingMath.ruleFill(situation, tightness: params.fillX)
        var offset = 0.0
        if let memory = learned[situation.rawValue], memory.count > 0 {
            let w = memory.weight
            fill = fill * (1.0 - w) + memory.fill * w
            offset = memory.offsetX * w
        }
        return (fill, offset)
    }

    // MARK: - Helpers

    private func keptPlayers(_ players: [NBox], trim: Bool) -> [NBox] {
        let p = params
        if !trim || players.count < p.trimMinPlayers {
            return players
        }
        let n = players.count
        let drop = Int(Double(n) * p.trimFraction)
        if drop <= 0 {
            return players
        }
        let byX = players.sorted { $0.center.x < $1.center.x }
        let keepX = Array(byX[drop..<(n - drop)])
        let byY = keepX.sorted { $0.center.y < $1.center.y }
        let m = byY.count
        let dropY = Int(Double(m) * p.trimFraction)
        if dropY <= 0 {
            return byY
        }
        return Array(byY[dropY..<(m - dropY)])
    }

    private func measurePlayers(_ players: [NBox], time: Double, dt: Double, trim: Bool) {
        let p = params
        if players.isEmpty {
            if havePlayers && (time - lastPlayersTime) > p.playersHold {
                havePlayers = false
            }
            return
        }
        let kept = keptPlayers(players, trim: trim)
        let count = Double(kept.count)
        var sumX = 0.0
        var sumY = 0.0
        var box = kept[0]
        for player in kept {
            sumX += player.center.x
            sumY += player.center.y
            box = box.union(player)
        }
        let cx = sumX / count
        let cy = sumY / count
        let left = cx - box.minX
        let right = box.maxX - cx
        let up = cy - box.minY
        let down = box.maxY - cy
        let heights = kept.map { $0.h }.sorted()
        playerHeight = heights[heights.count / 2]
        if !havePlayers {
            smCx = cx
            smCy = cy
            smLeft = left
            smRight = right
            smUp = up
            smDown = down
            playerCount = count
        } else {
            let a = 1.0 - exp(-dt / p.centerTau)
            let b = 1.0 - exp(-dt / p.sizeTau)
            playerCount += (count - playerCount) * b
            smCx += (cx - smCx) * a
            smCy += (cy - smCy) * a
            smLeft += (left - smLeft) * b
            smRight += (right - smRight) * b
            smUp += (up - smUp) * b
            smDown += (down - smDown) * b
        }
        havePlayers = true
        lastPlayersTime = time
    }

    private static func withDeadband(_ error: Double, _ band: Double) -> Double {
        if error > band {
            return error - band
        }
        if error < -band {
            return error + band
        }
        return 0.0
    }

    private func slew(_ current: Double, _ target: Double, _ dt: Double) -> Double {
        let limit = params.rateSlew * dt
        let step = Geo.clamp(target - current, -limit, limit)
        return Geo.clamp(current + step, -1.0, 1.0)
    }

    // MARK: - Main step

    func update(_ i: DirectorInput) -> DirectorOutput {
        let p = params
        var dt = 0.08
        if let previous = lastTime {
            dt = Geo.clamp(i.time - previous, 0.01, 0.5)
        }
        lastTime = i.time
        if !zoomInitialised {
            logZoom = log(Geo.clamp(i.zoom, i.zoomMin, i.zoomMax))
            zoomInitialised = true
        }

        var out = DirectorOutput()

        // ---- What is there to look at? ----
        // A fixed camera must keep everybody in view, so only trim when the mount can follow.
        measurePlayers(i.players, time: i.time, dt: dt, trim: i.mountActive)
        var ballUsable = false
        if let seen = i.ball, i.ballAge <= p.ballHold {
            ballUsable = true
            lastBall = seen
        }
        let weightStep = dt / p.ballBlendTime
        if ballUsable {
            ballWeight = min(1.0, ballWeight + weightStep)
        } else {
            ballWeight = max(0.0, ballWeight - weightStep)
        }
        let ball: NPoint? = ballWeight > 0.0 ? lastBall : nil
        let current = updateSituation(i, dt: dt)
        out.situation = current
        out.features = lastFeatures
        let shape = framing(for: current, learned: i.learned)

        var boxFound: NBox?
        var lookFound: NPoint?
        if havePlayers {
            var look = NPoint(x: smCx, y: smCy)
            var box = NBox(x: smCx - smLeft, y: smCy - smUp, w: smLeft + smRight, h: smUp + smDown)
            if current == .pile, let cluster = smCluster {
                // Frame the pile itself; the fill leaves room for the backs around it.
                box = cluster
                look = cluster.center
            }
            if let b = ball {
                let w = ballWeight
                box = box.including(NPoint(x: look.x + (b.x - look.x) * w,
                                           y: look.y + (b.y - look.y) * w))
                look = NPoint(x: look.x + (b.x - look.x) * p.ballBias * w,
                              y: look.y + (b.y - look.y) * p.ballBias * w)
            }
            boxFound = box
            lookFound = look
        } else if let b = ball {
            lookFound = b
            boxFound = NBox(x: b.x, y: b.y, w: 0.0, h: 0.0)
        }

        guard let box = boxFound, let foundLook = lookFound else {
            // Nothing to look at: stop turning, and after a while zoom out.
            out.state = .searching
            out.situation = .lost
            panIntegral *= exp(-dt / 0.5)
            panRate = slew(panRate, 0.0, dt)
            tiltRate = slew(tiltRate, 0.0, dt)
            if i.autoZoom && (i.time - lastActionTime) > p.searchDelay {
                let target = log(i.zoomMin)
                var step = (target - logZoom) * (1.0 - exp(-dt / (p.zoomTauOut * 2.0)))
                step = Geo.clamp(step, -p.zoomMaxLogRate * dt, p.zoomMaxLogRate * dt)
                logZoom += step
            }
            out.panRate = i.mountActive ? panRate : 0.0
            out.tiltRate = i.mountActive ? tiltRate : 0.0
            out.zoomTarget = i.autoZoom ? exp(logZoom) : i.zoom
            return out
        }

        lastActionTime = i.time
        var look = foundLook
        // A runner: leave room in front of them.
        if current == .breakaway, let v = i.ballVelocity {
            look.x += (v.x > 0 ? 1.0 : -1.0) * p.breakLead
        }
        // What the person showed: action a little to one side.
        if shape.offset != 0.0 {
            look.x += shape.offset * max(box.w, box.h) / max(shape.fill, 0.1)
        }
        look.x = Geo.clamp(look.x, 0.0, 1.0)
        if ballUsable {
            out.state = i.ballAge <= 0.25 ? .ball : .ballHeld
        } else {
            out.state = .players
        }
        out.actionBox = box
        out.lookAt = look

        // ---- Pan and tilt ----
        if i.mountActive {
            let fovScale = Geo.clamp(i.wideZoom / max(i.zoom, 0.01), 0.1, 1.5)
            let ex = Director.withDeadband(look.x - 0.5, p.panDeadband)
            let ey = Director.withDeadband(look.y - 0.5, p.tiltDeadband)
            panIntegral += p.panIntegralGain * ex * fovScale * dt
            panIntegral *= exp(-dt / p.integralLeak)
            panIntegral = Geo.clamp(panIntegral, -p.integralLimit, p.integralLimit)
            let panTarget = Geo.clamp(p.panGain * ex * fovScale + panIntegral, -1.0, 1.0)
            let tiltTarget = p.tiltEnabled ? Geo.clamp(p.tiltGain * ey * fovScale, -1.0, 1.0) : 0.0
            panRate = slew(panRate, panTarget, dt)
            tiltRate = slew(tiltRate, tiltTarget, dt)
            out.panRate = panRate
            out.tiltRate = tiltRate
        } else {
            panRate = 0.0
            tiltRate = 0.0
            panIntegral = 0.0
        }

        let usesSituation = p.situationsEnabled && current != .open
        let fillX = usesSituation || i.learned[current.rawValue] != nil ? shape.fill : p.fillX
        let fillY = usesSituation || i.learned[current.rawValue] != nil ? min(0.9, shape.fill + 0.05) : p.fillY
        out.frame = FramingMath.frame(around: box, fill: fillX, offsetX: shape.offset)

        // ---- Zoom ----
        if !i.autoZoom {
            logZoom = log(Geo.clamp(i.zoom, i.zoomMin, i.zoomMax))
            out.zoomTarget = i.zoom
            return out
        }

        let boxW = max(box.w, p.minBoxW)
        let boxH = max(box.h, p.minBoxH)
        var ratioFill = min(fillX / boxW, fillY / boxH)
        if havePlayers {
            let tallest = current == .pile ? p.pileMaxPlayerHeight : p.maxPlayerHeight
            ratioFill = min(ratioFill, tallest / max(playerHeight, 1.0e-3))
        }
        let kickStart = current == .kick && i.time - situationSince < 1.2
        if kickStart {
            // Go wide at once so the ball and the chasers stay in the picture.
            ratioFill = min(ratioFill, 0.55)
        }
        if !havePlayers || playerCount < Double(p.minPlayersForZoomIn) {
            // Too little to go on (ball only, or one or two people): hold the zoom.
            ratioFill = min(ratioFill, 1.0)
        }
        let half = 0.5 - p.safeMargin
        let reachX = max(abs(box.minX - 0.5), abs(box.maxX - 0.5), 1.0e-3)
        let reachY = max(abs(box.minY - 0.5), abs(box.maxY - 0.5), 1.0e-3)
        let ratioSafe = min(half / reachX, half / reachY)

        let urgent = ratioSafe < 1.0 || (kickStart && ratioFill < 1.0)
        let ratio = ratioSafe < 1.0 ? pow(ratioSafe, p.zoomUrgency) : min(ratioFill, ratioSafe)
        let desired = Geo.clamp(i.zoom * ratio, i.zoomMin, i.zoomMax)
        let target = log(desired)
        if urgent || abs(target - logZoom) >= p.zoomDeadband {
            let tau: Double
            if urgent {
                tau = p.zoomTauUrgent
            } else if target < logZoom {
                tau = p.zoomTauOut
            } else {
                tau = p.zoomTauIn
            }
            let step = (target - logZoom) * (1.0 - exp(-dt / tau))
            let maxStep = p.zoomMaxLogRate * dt * (urgent ? 2.0 : 1.0)
            logZoom += Geo.clamp(step, -maxStep, maxStep)
        }
        logZoom = Geo.clamp(logZoom, log(i.zoomMin), log(i.zoomMax))
        out.zoomTarget = exp(logZoom)
        return out
    }
}

/// Turns the smooth zoom into steps between the "optical" zoom levels of the
/// phone's lenses, with some hysteresis so it does not flip back and forth.
final class LensStepper {
    private(set) var stops: [Double] = []
    var downHysteresis = 0.90
    private var index = 0

    func setStops(_ newStops: [Double], current zoom: Double) {
        stops = newStops.sorted()
        setCurrent(zoom)
    }

    func setCurrent(_ zoom: Double) {
        index = floorIndex(zoom * 1.02)
    }

    private func floorIndex(_ zoom: Double) -> Int {
        var found = 0
        for (k, stop) in stops.enumerated() where stop <= zoom {
            found = k
        }
        return found
    }

    func step(_ smoothZoom: Double) -> Double {
        if stops.isEmpty {
            return smoothZoom
        }
        if index >= stops.count {
            index = stops.count - 1
        }
        let current = stops[index]
        if index + 1 < stops.count && smoothZoom >= stops[index + 1] {
            index = floorIndex(smoothZoom)
        } else if smoothZoom <= current * downHysteresis && index > 0 {
            index = floorIndex(smoothZoom)
        }
        return stops[index]
    }
}
