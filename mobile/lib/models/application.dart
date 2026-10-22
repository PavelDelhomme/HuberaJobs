import 'user.dart';
import 'company.dart';

class Application {
  final String id;
  final String position;
  final String description;
  final Company company;
  final String status;
  final String priority;
  final DateTime appliedDate;
  final DateTime? interviewDate;
  final String location;
  final String salary;
  final String notes;
  final List<String> tags;
  final User createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? agencyId;
  final String agencyName;
  final String? platformId;
  final String platformName;
  final String jobUrl;
  final String contractType;
  final String? workMode;
  final String applicationType;
  final int? salaryMin;
  final int? salaryMax;
  final bool salaryNegotiable;
  final bool statusEngineOptOut;

  const Application({
    required this.id,
    required this.position,
    required this.description,
    required this.company,
    required this.status,
    required this.priority,
    required this.appliedDate,
    this.interviewDate,
    required this.location,
    required this.salary,
    required this.notes,
    required this.tags,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.agencyId,
    this.agencyName = '',
    this.platformId,
    this.platformName = '',
    this.jobUrl = '',
    this.contractType = 'CDI',
    this.workMode,
    this.applicationType = 'OFFRE',
    this.salaryMin,
    this.salaryMax,
    this.salaryNegotiable = false,
    this.statusEngineOptOut = false,
  });

  bool get isInterim => agencyId != null && agencyId!.isNotEmpty;

  factory Application.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    String statusCode = '';
    if (status is Map) {
      statusCode = (status['code'] ?? status['name'] ?? '').toString();
    } else if (status != null) {
      statusCode = status.toString();
    }
    if (statusCode.isEmpty && json['statusId'] != null) {
      statusCode = json['statusId'].toString();
    }
    final appliedDate = json['applicationDate'] ?? json['appliedDate'];
    final rawTags = json['tags'];
    final tags = rawTags is List
        ? rawTags.map((t) => t?.toString() ?? '').where((t) => t.isNotEmpty).toList()
        : <String>[];
    final companyJson = json['company'];
    final companyId = json['companyId']?.toString() ?? '';
    Map<String, dynamic> companyMap;
    if (companyJson is Map) {
      companyMap = Map<String, dynamic>.from(companyJson);
      if ((companyMap['id'] == null || companyMap['id'].toString().isEmpty) && companyId.isNotEmpty) {
        companyMap['id'] = companyId;
      }
    } else {
      companyMap = {'id': companyId, 'name': ''};
    }
    final agencyJson = json['agency'];
    final agencyId = json['agencyId']?.toString();
    final agencyName = agencyJson is Map
        ? (agencyJson['name']?.toString() ?? '')
        : '';
    final platformJson = json['platform'];
    final platformId = json['platformId']?.toString() ??
        (platformJson is Map ? platformJson['id']?.toString() : null);
    final platformName = platformJson is Map ? (platformJson['name']?.toString() ?? '') : '';
    return Application(
      id: json['id']?.toString() ?? '',
      position: json['position']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      company: Company.fromJson(companyMap),
      status: statusCode,
      priority: json['priority']?.toString() ?? 'MEDIUM',
      appliedDate: appliedDate != null ? DateTime.tryParse(appliedDate.toString()) ?? DateTime.now() : DateTime.now(),
      interviewDate: json['interviewDate'] != null ? DateTime.tryParse(json['interviewDate'].toString()) : null,
      location: json['location']?.toString() ?? '',
      salary: json['salary']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      tags: tags,
      createdBy: json['createdBy'] is Map<String, dynamic>
          ? User.fromJson(json['createdBy'] as Map<String, dynamic>)
          : User.fromJson({}),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
      agencyId: agencyId,
      agencyName: agencyName,
      platformId: platformId,
      platformName: platformName,
      jobUrl: json['jobUrl']?.toString() ?? '',
      contractType: (json['contractType']?.toString().trim().isNotEmpty ?? false)
          ? json['contractType'].toString()
          : 'CDI',
      workMode: json['workMode']?.toString(),
      applicationType: (json['applicationType']?.toString().trim().isNotEmpty ?? false)
          ? json['applicationType'].toString()
          : 'OFFRE',
      salaryMin: _asInt(json['salaryMin']),
      salaryMax: _asInt(json['salaryMax']),
      salaryNegotiable: json['salaryNegotiable'] == true || json['salaryNegotiable'] == 'true',
      statusEngineOptOut: json['statusEngineOptOut'] == true || json['statusEngineOptOut'] == 'true',
    );
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse('${value ?? ''}'.trim());
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'position': position,
      'description': description,
      'company': company.toJson(),
      'status': status,
      'priority': priority,
      'appliedDate': appliedDate.toIso8601String(),
      'interviewDate': interviewDate?.toIso8601String(),
      'location': location,
      'salary': salary,
      'notes': notes,
      'tags': tags,
      'createdBy': createdBy.toJson(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (agencyId != null) 'agencyId': agencyId,
      if (platformId != null) 'platformId': platformId,
      if (jobUrl.isNotEmpty) 'jobUrl': jobUrl,
      'contractType': contractType,
      if (workMode != null && workMode!.isNotEmpty) 'workMode': workMode,
      'applicationType': applicationType,
      if (salaryMin != null) 'salaryMin': salaryMin,
      if (salaryMax != null) 'salaryMax': salaryMax,
      'salaryNegotiable': salaryNegotiable,
      'statusEngineOptOut': statusEngineOptOut,
    };
  }
}
