import Foundation
import MetricKit
import os

enum ChartSignpostStage {
    case ingress
    case sceneBuild
    case metalEncode
    case presented

    var name: StaticString {
        switch self {
        case .ingress:
            "Chart ingress"
        case .sceneBuild:
            "Chart scene build"
        case .metalEncode:
            "Chart Metal encode"
        case .presented:
            "Chart presented"
        }
    }
}

enum ChartSignposts {
    private static let log = MXMetricManager.makeLogHandle(
        category: "KlineChart"
    )

    static func begin(
        _ stage: ChartSignpostStage,
        revision: UInt64
    ) -> OSSignpostID {
        let identifier = OSSignpostID(log: log)
        os_signpost(
            .begin,
            log: log,
            name: stage.name,
            signpostID: identifier,
            "revision=%{public}llu",
            revision
        )
        return identifier
    }

    static func end(
        _ stage: ChartSignpostStage,
        identifier: OSSignpostID,
        revision: UInt64
    ) {
        os_signpost(
            .end,
            log: log,
            name: stage.name,
            signpostID: identifier,
            "revision=%{public}llu",
            revision
        )
    }
}
