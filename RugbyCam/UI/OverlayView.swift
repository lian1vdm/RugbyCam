import SwiftUI

/// Draws what the tracking sees on top of the live picture:
/// players (thin cyan boxes), the framed action (dashed green), the area the
/// ball search looked at (yellow), the ball (red ring, orange until confirmed)
/// and the point the camera is aiming at (white cross).
struct TrackingOverlay: View {
    let snapshot: TrackingSnapshot

    var body: some View {
        Canvas { context, size in
            let video = VideoLayout.videoRect(in: size)

            for player in snapshot.players {
                let rect = TrackingOverlay.place(player, in: video)
                context.stroke(Path(rect), with: .color(Color.cyan.opacity(0.8)), lineWidth: 1.0)
            }

            if let area = snapshot.searchArea, area != NBox.full {
                let rect = TrackingOverlay.place(area, in: video)
                context.stroke(Path(rect), with: .color(Color.yellow.opacity(0.5)), lineWidth: 1.0)
            }

            if let action = snapshot.actionBox {
                let rect = TrackingOverlay.place(action, in: video)
                context.stroke(Path(roundedRect: rect, cornerRadius: 4.0),
                               with: .color(Color.green.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2.0, dash: [8.0, 6.0]))
            }

            if let ball = snapshot.ball {
                let rect = TrackingOverlay.place(ball, in: video).insetBy(dx: -7.0, dy: -7.0)
                let colour = snapshot.ballConfirmed ? Color.red : Color.orange
                context.stroke(Path(ellipseIn: rect), with: .color(colour), lineWidth: 2.5)
            }

            if let aim = snapshot.lookAt {
                let x = video.minX + CGFloat(aim.x) * video.width
                let y = video.minY + CGFloat(aim.y) * video.height
                var cross = Path()
                cross.move(to: CGPoint(x: x - 9.0, y: y))
                cross.addLine(to: CGPoint(x: x + 9.0, y: y))
                cross.move(to: CGPoint(x: x, y: y - 9.0))
                cross.addLine(to: CGPoint(x: x, y: y + 9.0))
                context.stroke(cross, with: .color(Color.white.opacity(0.9)), lineWidth: 1.5)
            }
        }
    }

    /// Converts a box in picture coordinates (0...1) into screen points.
    private static func place(_ box: NBox, in video: CGRect) -> CGRect {
        return CGRect(x: video.minX + CGFloat(box.x) * video.width,
                      y: video.minY + CGFloat(box.y) * video.height,
                      width: CGFloat(box.w) * video.width,
                      height: CGFloat(box.h) * video.height)
    }
}
