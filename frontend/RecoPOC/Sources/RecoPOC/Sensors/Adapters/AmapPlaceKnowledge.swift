import Foundation

enum AmapPlaceKnowledgeError: Error, Equatable, CustomStringConvertible, Sendable {
    case bundledResourceMissing
    case invalidPlaceType(String)
    case emptySourceLabel(String)
    case invalidAroundTypePrefix(String)
    case invalidTypecodeRulePrefix(String)
    case unorderedBands(String)
    case thresholdConflict(String)
    case invalidKeywordRule(String)
    case invalidProviderTypeRule(String)

    var description: String {
        switch self {
        case .bundledResourceMissing:
            return "Bundled AMap place knowledge resource is missing."
        case .invalidPlaceType(let placeType):
            return "Invalid place type in AMap place knowledge: \(placeType)"
        case .emptySourceLabel(let key):
            return "AMap place knowledge source label is empty: \(key)"
        case .invalidAroundTypePrefix(let prefix):
            return "AMap place knowledge has invalid around query type prefix: \(prefix)"
        case .invalidTypecodeRulePrefix(let prefix):
            return "AMap place knowledge has invalid typecode rule prefix: \(prefix)"
        case .unorderedBands(let key):
            return "AMap place knowledge bands are not strictly ordered: \(key)"
        case .thresholdConflict(let key):
            return "AMap place knowledge thresholds conflict: \(key)"
        case .invalidKeywordRule(let key):
            return "AMap place knowledge keyword rule is invalid: \(key)"
        case .invalidProviderTypeRule(let key):
            return "AMap place knowledge provider type rule is invalid: \(key)"
        }
    }
}

enum TypecodeStrength: String, Decodable, Equatable, Sendable {
    case strong
    case mediumStrong = "mediumStrong"
    case coarse
    case container
    case none
}

struct AmapPlaceKnowledge: Decodable, Sendable {
    struct Query: Decodable, Sendable {
        var aroundPageSize: Int
        var aroundShowFields: String
        var aroundTypePrefixes: [String]
        var regeoExtensions: String
        var regeoRoadLevel: Int
        var regeoHomeOrCorp: Int

        var aroundTypesFilter: String {
            aroundTypePrefixes.joined(separator: "|")
        }
    }

    struct Keywords: Decodable, Sendable {
        var containerKeywords: [String]
        var dormitoryKeywords: [String]
        var strongRules: [KeywordRule]
        var weakRules: [KeywordRule]
    }

    struct KeywordRule: Decodable, Equatable, Sendable {
        var placeType: String
        var tag: String
        var keywords: [String]
    }

    struct ProviderTypeRule: Decodable, Equatable, Sendable {
        var placeType: String
        var matchSegments: [String]
    }

    struct TypecodeRule: Decodable, Equatable, Sendable {
        var prefix: String
        var placeType: String
        var strength: TypecodeStrength
        var requiresStrongKeywordPlaceType: String?
        var requiresWeakKeywordPlaceType: String?
        var requiresProviderTypePlaceType: String?
        var requiresContainerEvidence: Bool?
    }

    struct SourceLabels: Decodable, Sendable {
        var regeoAOI: String
        var regeoBuilding: String
        var regeoNeighborhood: String
        var regeoPOI: String
        var aroundTypecodeName: String
        var aroundTypecode: String
        var aroundNameKeyword: String
        var fusedEvidence: String
        var unavailable: String

        var all: [(String, String)] {
            [
                ("regeoAOI", regeoAOI),
                ("regeoBuilding", regeoBuilding),
                ("regeoNeighborhood", regeoNeighborhood),
                ("regeoPOI", regeoPOI),
                ("aroundTypecodeName", aroundTypecodeName),
                ("aroundTypecode", aroundTypecode),
                ("aroundNameKeyword", aroundNameKeyword),
                ("fusedEvidence", fusedEvidence),
                ("unavailable", unavailable)
            ]
        }
    }

    struct Scoring: Decodable, Sendable {
        struct Structural: Decodable, Sendable {
            var containerAOINear: Double
            var containerAOIFar: Double
            var containerBuildingOrNeighborhood: Double
            var regeoAOIResidentialNear: Double
            var regeoAOIResidentialFar: Double
            var regeoAOIMallNear: Double
            var regeoAOIMallFar: Double
            var regeoAOIDefaultNear: Double
            var regeoAOIDefaultFar: Double
            var regeoBuildingDormResidential: Double
            var regeoBuildingResidential: Double
            var regeoBuildingMallOrOffice: Double
            var regeoBuildingDefault: Double
            var regeoNeighborhoodResidential: Double
            var regeoNeighborhoodDefault: Double
            var accuracyPenaltyMultiplier: Double
            var staleSamplePenalty: Double
            var maxConfidence: Double
        }

        struct ValueBand: Decodable, Sendable {
            var maxDistanceM: Double
            var value: Double
        }

        struct AccuracyPenaltyBand: Decodable, Sendable {
            var maxAccuracyM: Double
            var penalty: Double
        }

        struct TypecodeStrengthScores: Decodable, Sendable {
            var strong: Double
            var mediumStrong: Double
            var coarse: Double
            var container: Double
        }

        struct POIBoosts: Decodable, Sendable {
            var keywordMatchesTypecode: Double
            var coarseTypecodeRefinement: Double
            var weakKeywordAlignedWithTypecode: Double
            var nameOnly: Double
            var typeOnly: Double
            var topRank: Double
            var nearTopRank: Double
            var aroundRegeoAgreement: Double
            var regeoPOIAgreement: Double
        }

        struct POIPenalties: Decodable, Sendable {
            var nameConflict: Double
            var typeTextConflict: Double
            var staleSample: Double
        }

        struct POICaps: Decodable, Sendable {
            var strongNear: Double
            var strongFar: Double
            var mediumStrong: Double
            var coarseWithFunctionEvidence: Double
            var coarseOnly: Double
            var container: Double
            var nameOnly: Double
            var typeOnly: Double
            var regeoPOIMax: Double
            var aroundRegeoAgreement: Double
        }

        struct Fusion: Decodable, Sendable {
            var secondWeight: Double
            var thirdWeight: Double
            var structuralBonus: Double
            var structuralAroundBonus: Double
            var missingStructuralPenalty: Double
            var maxConfidence: Double
        }

        struct Quality: Decodable, Sendable {
            var minimumAvailableConfidence: Double
            var exactOrGoodMinConfidence: Double
            var closeRunnerUpMinConfidence: Double
            var closeRunnerUpMaxMargin: Double
        }

        var regeoRadiusMinM: Double
        var regeoRadiusMaxM: Double
        var regeoRadiusAccuracyMultiplier: Double
        var aroundRadiusMaxM: Double
        var structural: Structural
        var poiDistanceScoreBands: [ValueBand]
        var poiDistanceCapBands: [ValueBand]
        var accuracyPenaltyBands: [AccuracyPenaltyBand]
        var typecodeStrengthScores: TypecodeStrengthScores
        var poiBoosts: POIBoosts
        var poiPenalties: POIPenalties
        var poiCaps: POICaps
        var fusion: Fusion
        var quality: Quality
    }

    var query: Query
    var keywords: Keywords
    var providerTypeRules: [ProviderTypeRule]
    var typecodeRules: [TypecodeRule]
    var scoring: Scoring
    var sourceLabels: SourceLabels

    static let allowedPlaceTypes: Set<String> = [
        "任意",
        "住宅区",
        "商场",
        "酒店",
        "餐厅",
        "公园",
        "写字楼",
        "机场",
        "图书馆",
        "海边",
        "户外",
        "在途",
        "高铁站",
        "地铁站",
        "运动场所"
    ]

    static func bundled() throws -> AmapPlaceKnowledge {
        try AmapPlaceKnowledgeLoader.knowledge()
    }

    static func bundledData() throws -> Data {
        try AmapPlaceKnowledgeLoader.bundledData()
    }

    static func load(data: Data) throws -> AmapPlaceKnowledge {
        let knowledge = try JSONDecoder().decode(AmapPlaceKnowledge.self, from: data)
        try knowledge.validate()
        return knowledge
    }

    func typecodeScore(for strength: TypecodeStrength) -> Double {
        switch strength {
        case .strong:
            return scoring.typecodeStrengthScores.strong
        case .mediumStrong:
            return scoring.typecodeStrengthScores.mediumStrong
        case .coarse:
            return scoring.typecodeStrengthScores.coarse
        case .container:
            return scoring.typecodeStrengthScores.container
        case .none:
            return 0
        }
    }
}

private enum AmapPlaceKnowledgeLoader {
    static func knowledge() throws -> AmapPlaceKnowledge {
        try result.get()
    }

    static func bundledData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "AmapPlaceKnowledge", withExtension: "json") else {
            throw AmapPlaceKnowledgeError.bundledResourceMissing
        }
        return try Data(contentsOf: url)
    }

    private static let result: Result<AmapPlaceKnowledge, Error> = Result {
        try AmapPlaceKnowledge.load(data: bundledData())
    }
}

private extension AmapPlaceKnowledge {
    func validate() throws {
        try validateQuery()
        try validateKeywordRules(keywords.strongRules, name: "keywords.strongRules")
        try validateKeywordRules(keywords.weakRules, name: "keywords.weakRules")
        try validateProviderTypeRules()
        try validateTypecodeRules()
        try validateSourceLabels()
        try validateScoring()
    }

    func validateQuery() throws {
        guard query.aroundPageSize > 0 else {
            throw AmapPlaceKnowledgeError.thresholdConflict("query.aroundPageSize")
        }
        guard !query.aroundShowFields.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AmapPlaceKnowledgeError.thresholdConflict("query.aroundShowFields")
        }
        guard query.regeoRoadLevel >= 0 else {
            throw AmapPlaceKnowledgeError.thresholdConflict("query.regeoRoadLevel")
        }
        guard query.regeoHomeOrCorp >= 0 else {
            throw AmapPlaceKnowledgeError.thresholdConflict("query.regeoHomeOrCorp")
        }
        guard !query.aroundTypePrefixes.isEmpty else {
            throw AmapPlaceKnowledgeError.thresholdConflict("query.aroundTypePrefixes")
        }
        for prefix in query.aroundTypePrefixes {
            guard Self.isSixDigitPrefix(prefix) else {
                throw AmapPlaceKnowledgeError.invalidAroundTypePrefix(prefix)
            }
        }
    }

    func validateKeywordRules(_ rules: [KeywordRule], name: String) throws {
        guard !rules.isEmpty else {
            throw AmapPlaceKnowledgeError.invalidKeywordRule(name)
        }
        for rule in rules {
            try validatePlaceType(rule.placeType)
            guard !rule.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AmapPlaceKnowledgeError.invalidKeywordRule(name)
            }
            guard !rule.keywords.isEmpty,
                  rule.keywords.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw AmapPlaceKnowledgeError.invalidKeywordRule(name)
            }
        }
    }

    func validateProviderTypeRules() throws {
        guard !providerTypeRules.isEmpty else {
            throw AmapPlaceKnowledgeError.invalidProviderTypeRule("providerTypeRules")
        }
        for rule in providerTypeRules {
            try validatePlaceType(rule.placeType)
            guard !rule.matchSegments.isEmpty,
                  rule.matchSegments.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw AmapPlaceKnowledgeError.invalidProviderTypeRule(rule.placeType)
            }
        }
    }

    func validateTypecodeRules() throws {
        guard !typecodeRules.isEmpty else {
            throw AmapPlaceKnowledgeError.invalidTypecodeRulePrefix("typecodeRules")
        }
        for rule in typecodeRules {
            try validatePlaceType(rule.placeType)
            guard Self.isNumericPrefix(rule.prefix) else {
                throw AmapPlaceKnowledgeError.invalidTypecodeRulePrefix(rule.prefix)
            }
            if let placeType = rule.requiresStrongKeywordPlaceType {
                try validatePlaceType(placeType)
            }
            if let placeType = rule.requiresWeakKeywordPlaceType {
                try validatePlaceType(placeType)
            }
            if let placeType = rule.requiresProviderTypePlaceType {
                try validatePlaceType(placeType)
            }
        }
    }

    func validateSourceLabels() throws {
        for (key, value) in sourceLabels.all {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("amap_") else {
                throw AmapPlaceKnowledgeError.emptySourceLabel(key)
            }
        }
    }

    func validateScoring() throws {
        guard scoring.regeoRadiusMinM > 0,
              scoring.regeoRadiusMaxM >= scoring.regeoRadiusMinM,
              scoring.regeoRadiusAccuracyMultiplier > 0,
              scoring.aroundRadiusMaxM > 0
        else {
            throw AmapPlaceKnowledgeError.thresholdConflict("scoring.radius")
        }
        try validateOrderedDistanceBands(scoring.poiDistanceScoreBands, name: "scoring.poiDistanceScoreBands")
        try validateOrderedDistanceBands(scoring.poiDistanceCapBands, name: "scoring.poiDistanceCapBands")
        try validateOrderedAccuracyBands(scoring.accuracyPenaltyBands, name: "scoring.accuracyPenaltyBands")

        let quality = scoring.quality
        guard quality.minimumAvailableConfidence >= 0,
              quality.exactOrGoodMinConfidence >= quality.minimumAvailableConfidence,
              quality.exactOrGoodMinConfidence <= 1,
              quality.closeRunnerUpMinConfidence >= 0,
              quality.closeRunnerUpMinConfidence <= 1,
              quality.closeRunnerUpMaxMargin >= 0,
              scoring.fusion.maxConfidence >= quality.exactOrGoodMinConfidence,
              scoring.structural.maxConfidence >= quality.exactOrGoodMinConfidence
        else {
            throw AmapPlaceKnowledgeError.thresholdConflict("scoring.quality")
        }
    }

    func validateOrderedDistanceBands(_ bands: [Scoring.ValueBand], name: String) throws {
        guard !bands.isEmpty else {
            throw AmapPlaceKnowledgeError.unorderedBands(name)
        }
        var previous = -Double.infinity
        for band in bands {
            guard band.maxDistanceM > previous else {
                throw AmapPlaceKnowledgeError.unorderedBands(name)
            }
            previous = band.maxDistanceM
        }
    }

    func validateOrderedAccuracyBands(_ bands: [Scoring.AccuracyPenaltyBand], name: String) throws {
        guard !bands.isEmpty else {
            throw AmapPlaceKnowledgeError.unorderedBands(name)
        }
        var previous = -Double.infinity
        for band in bands {
            guard band.maxAccuracyM > previous else {
                throw AmapPlaceKnowledgeError.unorderedBands(name)
            }
            previous = band.maxAccuracyM
        }
    }

    func validatePlaceType(_ placeType: String) throws {
        guard Self.allowedPlaceTypes.contains(placeType) else {
            throw AmapPlaceKnowledgeError.invalidPlaceType(placeType)
        }
    }

    static func isSixDigitPrefix(_ value: String) -> Bool {
        value.count == 6 && value.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
    }

    static func isNumericPrefix(_ value: String) -> Bool {
        (2...6).contains(value.count) && value.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
    }
}
