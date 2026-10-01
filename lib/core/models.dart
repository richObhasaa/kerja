/// Port Dart dari `src/types.ts`.
///
/// Nama field JSON dipertahankan snake_case agar cocok dengan prompt template
/// dan kontrak API di `gas/README.md`.
library;

enum MatchLevel {
  high('HIGH'),
  medium('MEDIUM'),
  low('LOW');

  const MatchLevel(this.wire);
  final String wire;

  static MatchLevel fromWire(Object? value, {MatchLevel fallback = MatchLevel.low}) {
    final v = value?.toString().trim().toUpperCase();
    for (final level in MatchLevel.values) {
      if (level.wire == v) return level;
    }
    return fallback;
  }

  /// Ambang batas mengikuti aturan di `career_intelligence_engine.txt`:
  /// 80-100 HIGH, 50-79 MEDIUM, 0-49 LOW.
  static MatchLevel fromScore(num score) {
    if (score >= 80) return MatchLevel.high;
    if (score >= 50) return MatchLevel.medium;
    return MatchLevel.low;
  }
}

class JobInfo {
  const JobInfo({required this.title, required this.company, required this.location});

  final String title;
  final String company;
  final String location;

  factory JobInfo.fromJson(Map<String, dynamic> json) => JobInfo(
        title: (json['title'] ?? '').toString(),
        company: (json['company'] ?? '').toString(),
        location: (json['location'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'title': title, 'company': company, 'location': location};
}

class MatchAnalysis {
  const MatchAnalysis({
    required this.matchScore,
    required this.matchLevel,
    required this.keyMatchingSkills,
    required this.missingRequirements,
    required this.matchReason,
  });

  final int matchScore;
  final MatchLevel matchLevel;
  final List<String> keyMatchingSkills;
  final List<String> missingRequirements;
  final String matchReason;

  factory MatchAnalysis.fromJson(Map<String, dynamic> json) {
    final score = _clampScore(json['match_score']);
    return MatchAnalysis(
      matchScore: score,
      matchLevel: MatchLevel.fromWire(json['match_level'], fallback: MatchLevel.fromScore(score)),
      keyMatchingSkills: _stringList(json['key_matching_skills']),
      missingRequirements: _stringList(json['missing_requirements']),
      matchReason: (json['match_reason'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'match_score': matchScore,
        'match_level': matchLevel.wire,
        'key_matching_skills': keyMatchingSkills,
        'missing_requirements': missingRequirements,
        'match_reason': matchReason,
      };
}

class ApplicationMaterials {
  const ApplicationMaterials({required this.tailoredSummary, required this.coverLetter});

  final String tailoredSummary;
  final String coverLetter;

  factory ApplicationMaterials.fromJson(Map<String, dynamic> json) => ApplicationMaterials(
        tailoredSummary: (json['tailored_summary'] ?? '').toString(),
        coverLetter: (json['cover_letter'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'tailored_summary': tailoredSummary,
        'cover_letter': coverLetter,
      };
}

class CareerAnalysisResult {
  const CareerAnalysisResult({
    required this.jobInfo,
    required this.matchAnalysis,
    required this.applicationMaterials,
  });

  final JobInfo jobInfo;
  final MatchAnalysis matchAnalysis;
  final ApplicationMaterials applicationMaterials;

  factory CareerAnalysisResult.fromJson(Map<String, dynamic> json) => CareerAnalysisResult(
        jobInfo: JobInfo.fromJson(_asMap(json['job_info'])),
        matchAnalysis: MatchAnalysis.fromJson(_asMap(json['match_analysis'])),
        applicationMaterials: ApplicationMaterials.fromJson(_asMap(json['application_materials'])),
      );

  Map<String, dynamic> toJson() => {
        'job_info': jobInfo.toJson(),
        'match_analysis': matchAnalysis.toJson(),
        'application_materials': applicationMaterials.toJson(),
      };
}

/// Lowongan mentah dari aggregator.
///
/// [jobUrl] tidak ada di `src/types.ts`, tapi wajib ada di sisi Dart: objek
/// `JobInfo` hasil Gemini tidak memuat URL, sementara `save_analysis` di GAS
/// membutuhkan `job_url` terpisah sebagai kunci upsert/anti-duplikat.
class JobPosting {
  const JobPosting({
    required this.title,
    required this.company,
    required this.location,
    required this.description,
    required this.jobUrl,
    this.source = '',
  });

  final String title;
  final String company;
  final String location;
  final String description;
  final String jobUrl;

  /// Nama API asal loker (`JSearch`, `SerpAPI`), untuk label di UI.
  final String source;

  factory JobPosting.fromJson(Map<String, dynamic> json) => JobPosting(
        title: (json['title'] ?? '').toString(),
        company: (json['company'] ?? json['employer_name'] ?? '').toString(),
        location: (json['location'] ?? '').toString(),
        description: (json['description'] ?? json['job_description'] ?? '').toString(),
        jobUrl: (json['job_url'] ?? json['job_apply_link'] ?? json['url'] ?? '').toString(),
        source: (json['source'] ?? json['job_publisher'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'company': company,
        'location': location,
        'description': description,
        'job_url': jobUrl,
        'source': source,
      };
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

int _clampScore(Object? value) {
  final n = num.tryParse(value.toString());
  if (n == null) return 0;
  return n.round().clamp(0, 100);
}
