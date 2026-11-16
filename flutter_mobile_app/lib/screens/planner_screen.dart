import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoDatePicker, CupertinoDatePickerMode;
import 'package:flutter/services.dart'
    show TextInputFormatter, TextEditingValue;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import '../theme/app_theme.dart';
import '../models/user_model.dart';
import '../utils/planner_marketplaces.dart';
import '../utils/planner_operation_messages.dart';
import '../utils/visit_plan_validation.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../services/stuck_work.dart';
import '../services/visit_submission.dart';
import '../widgets/app_icon_button.dart';
import '../widgets/phone_card.dart';
import '../widgets/planner_visit_form.dart';

class _SafeTextFormatter extends TextInputFormatter {
  _SafeTextFormatter({required this.maxLength});
  final int maxLength;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String text = newValue.text;
    text = text.replaceAll(
      RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u200B\u202A-\u202E]'),
      '',
    );
    text = text.replaceAll(RegExp(r'[<>]'), '');
    if (text.length > maxLength) {
      text = text.substring(0, maxLength);
    }
    final int offset = newValue.selection.end.clamp(0, text.length);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key});

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class Visit {
  String id;
  String marketplace;
  String? time;
  String? purpose;
  String? notes;
  String date;
  String status;
  int progress;

  Visit({
    required this.id,
    required this.marketplace,
    this.time,
    this.purpose,
    this.notes,
    required this.date,
    this.status = 'Planned',
    this.progress = 0,
  });
}

class DateSchedule {
  DateTime date;
  List<Visit> visits;
  DateSchedule({required this.date, required this.visits});
}

class WeekSchedule {
  DateTime startDate;
  List<DateSchedule> dates;
  WeekSchedule({required this.startDate, required this.dates});
}

class _PlannerScreenState extends State<PlannerScreen>
    with SingleTickerProviderStateMixin {
  WeekSchedule? currentWeek;
  bool _loading = true;
  String? _loadError;
  bool _savingPlan = false;
  String? _draftVisitId;
  List<DateTime> weekStarts = [];
  int currentWeekIndex = 0;
  List<String> _marketplaces = [];
  String? _retailerLoadError;
  List<Visit> _allVisits = [];
  late DateTime _selectedStartDate;

  final Map<String, bool> _expandedDates = {};

  String? _mode;
  Visit? _editingVisit;

  DateTime? _selectedDate;
  String? _selectedTime;
  String? _selectedMarketplace;
  String? _selectedPurpose;
  String? _selectedNotes;
  String? _formError;
  bool _purposeAutoFilled = false;

  final TextEditingController _purposeController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  final List<String> workingHours = [
    '09:00',
    '09:30',
    '10:00',
    '10:30',
    '11:00',
    '11:30',
    '12:00',
    '12:30',
    '13:00',
    '13:30',
    '14:00',
    '14:30',
    '15:00',
    '15:30',
    '16:00',
    '16:30',
    '17:00',
  ];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedStartDate = _mondayOfWeek(now);
    _generateWeekStarts();
    _loadInitialData();
  }

  @override
  void dispose() {
    _purposeController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _generateWeekStarts() {
    weekStarts.clear();

    DateTime currentMonday = _mondayOfWeek(_selectedStartDate);

    for (int i = 4; i > 0; i--) {
      weekStarts.add(currentMonday.subtract(Duration(days: 7 * i)));
    }

    weekStarts.add(currentMonday);
    currentWeekIndex = 4;

    for (int i = 1; i <= 26; i++) {
      weekStarts.add(currentMonday.add(Duration(days: 7 * i)));
    }
  }

  void _ensureEnoughWeeks() {
    if (weekStarts.isEmpty) return;

    if (currentWeekIndex >= weekStarts.length - 3) {
      DateTime lastDate = weekStarts.last;
      for (int i = 0; i < 26; i++) {
        lastDate = lastDate.add(const Duration(days: 7));
        weekStarts.add(lastDate);
      }
    }
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await Future.wait([
        fetchSchedule(surfaceErrors: true),
        _fetchMarketplaces(),
      ]).timeout(const Duration(seconds: 12));
    } catch (e, stackTrace) {
      debugPrint('Error loading planner: $e\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _loadError =
            'Planner data could not be loaded. Check your connection and retry.';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _fetchMarketplaces() async {
    final UserModel? user = mounted ? context.read<AuthProvider>().user : null;
    if (user == null) {
      if (mounted) setState(() => _marketplaces = <String>[]);
      return;
    }

    final List<RetailerAssignmentQuery> assignmentQueries =
        retailerAssignmentQueries(
          staffId: user.staffId,
          uid: user.uid,
          branchId: user.branchId,
        );
    bool refused = false;
    final List<List<Map<String, dynamic>>>
    results = await Future.wait<List<Map<String, dynamic>>>(
      assignmentQueries.map((RetailerAssignmentQuery query) async {
        try {
          final QuerySnapshot<Map<String, dynamic>> snapshot = await query
              .apply(FirebaseFirestore.instance.collection('retailers'))
              .limit(1000)
              .get();
          return snapshot.docs
              .map(
                (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                    <String, dynamic>{...doc.data(), 'docId': doc.id},
              )
              .toList(growable: false);
        } catch (error) {
          if (isRetailerReadRefused(error)) refused = true;
          debugPrint(
            'Retailer assignment lookup failed for ${query.field}'
            '=${query.value}: $error',
          );
          return const <Map<String, dynamic>>[];
        }
      }),
    );
    final Map<String, Map<String, dynamic>> assignedById =
        <String, Map<String, dynamic>>{};
    for (final List<Map<String, dynamic>> rows in results) {
      for (final Map<String, dynamic> row in rows) {
        assignedById['${row['docId']}'] = row;
      }
    }
    final List<Map<String, dynamic>> assignedRows = assignedById.values.toList(
      growable: false,
    );

    final List<String> marketplaces = plannerMarketplaces(
      assignedRetailerRows: assignedRows,
    ).toList()..sort();
    if (!mounted) return;
    setState(() {
      _marketplaces = marketplaces;
      _retailerLoadError = refused && marketplaces.isEmpty
          ? kRetailerReadRefusedMessage
          : null;
    });
  }

  Future<void> fetchSchedule({
    bool surfaceErrors = false,
    Source source = Source.serverAndCache,
  }) async {
    try {
      if (weekStarts.isEmpty) return;

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        _allVisits = [];
        _buildCurrentWeek(const []);
        return;
      }

      final snap = await FirebaseFirestore.instance
          .collection('visits')
          .where('ownerUid', isEqualTo: uid)
          .limit(500)
          .get(GetOptions(source: source));

      _allVisits = snap.docs.map(_visitFromDoc).toList();
      _buildCurrentWeek(snap.docs);
      if (source != Source.cache) unawaited(_repairSubmitted(uid, snap.docs));
    } catch (e) {
      debugPrint('Error fetching schedule: $e');
      if (surfaceErrors) rethrow;
    }
  }

  Future<void> _repairSubmitted(
    String uid,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> visits,
  ) async {
    final int repaired = await repairSubmittedVisits(
      FirebaseFirestore.instance,
      uid: uid,
      visits: visits,
    );
    if (repaired > 0 && mounted) await fetchSchedule(source: Source.cache);
  }

  static int _asProgress(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  Visit _visitFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return Visit(
      id: doc.id,
      marketplace: data['marketplace'] as String? ?? '',
      time: data['time'] as String?,
      purpose: data['purpose'] as String?,
      notes: data['notes'] as String?,
      date: data['date'] as String? ?? '',
      status: data['status'] as String? ?? 'Planned',
      progress: _asProgress(data['progress']),
    );
  }

  void _buildCurrentWeek(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    if (currentWeekIndex >= weekStarts.length) return;

    final weekStart = weekStarts[currentWeekIndex];
    List<DateSchedule> dates = [];

    for (int d = 0; d < 7; d++) {
      final date = weekStart.add(Duration(days: d));
      final dateStr = _dateString(date);
      final visits = docs
          .where((doc) => doc.data()['date'] == dateStr)
          .map(_visitFromDoc)
          .toList();
      visits.sort(
        (a, b) =>
            _parseTimeToMinutes(a.time).compareTo(_parseTimeToMinutes(b.time)),
      );
      dates.add(DateSchedule(date: date, visits: visits));
    }

    if (!mounted) return;
    setState(() {
      currentWeek = WeekSchedule(startDate: weekStart, dates: dates);
    });
  }

  Future<bool> addVisit(Visit visit) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      debugPrint('Cannot add visit: no signed-in user');
      return false;
    }
    final visitDate = DateTime.parse(visit.date);
    final dateStr = _dateString(visitDate);
    final UserModel? profile = mounted
        ? context.read<AuthProvider>().user
        : null;
    final String identityCode = profile?.identityCode ?? '';
    final String salesmanCode = identityCode == uid ? '' : identityCode;
    final String branchId = profile?.branchId.trim() ?? '';
    try {
      final data = {
        'ownerUid': uid,
        'salesmanUid': uid,
        if (salesmanCode.isNotEmpty) 'salesmanCode': salesmanCode,
        if (branchId.isNotEmpty) 'branchId': branchId,
        'marketplace': visit.marketplace,
        'time': visit.time,
        'purpose': visit.purpose,
        'notes': visit.notes,
        'date': dateStr,
        'day': _dayName(visitDate),
      };
      final docId = <String>[
        uid,
        dateStr,
        visit.time ?? '',
        visit.marketplace,
        visit.id,
      ].map(_safeVisitDocPart).join('_');
      final bool queued = await HeldVisits(
        firestore: FirebaseFirestore.instance,
      ).save(uid, docId: docId, fields: data, update: false);
      if (!queued) await Future.delayed(const Duration(milliseconds: 500));
      await fetchSchedule(
        source: queued ? Source.cache : Source.serverAndCache,
      );
      return queued;
    } catch (e) {
      debugPrint('Error adding visit: $e');
      rethrow;
    }
  }

  Future<bool> updateVisit(Visit visit) async {
    try {
      final bool queued =
          await HeldVisits(firestore: FirebaseFirestore.instance).save(
            FirebaseAuth.instance.currentUser?.uid ?? '',
            docId: visit.id,
            fields: <String, Object?>{
              'marketplace': visit.marketplace,
              'time': visit.time,
              'purpose': visit.purpose,
              'notes': visit.notes,
              'date': visit.date,
            },
            update: true,
          );
      await fetchSchedule(
        source: queued ? Source.cache : Source.serverAndCache,
      );
      return queued;
    } catch (e) {
      debugPrint('Error updating visit: $e');
      rethrow;
    }
  }

  Future<void> confirmAndDeleteVisit(String visitId) async {
    final bool? confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: const Text('Delete this visit?'),
        content: const Text('This removes the visit from your planner.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await deleteVisit(visitId);
  }

  Future<void> deleteVisit(String visitId) async {
    try {
      await FirebaseFirestore.instance
          .collection('visits')
          .doc(visitId)
          .delete();
      await fetchSchedule();
    } catch (e) {
      debugPrint('Error deleting visit: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(plannerDeleteFailureMessage(e)),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  static String _dateString(DateTime dt) =>
      "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";

  static String _safeVisitDocPart(Object? value) {
    final cleaned = (value ?? '')
        .toString()
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return cleaned.isEmpty ? 'part' : cleaned;
  }

  static DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  static DateTime _mondayOfWeek(DateTime dt) {
    final date = _dateOnly(dt);
    return date.subtract(Duration(days: date.weekday - DateTime.monday));
  }

  static String _displayDateString(DateTime dt) =>
      "${dt.day.toString().padLeft(2, '0')} ${_month(dt.month)} ${dt.year}";

  static String _month(int m) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[m];
  }

  String _dayName(DateTime date) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return days[date.weekday - 1];
  }

  String _dayNameShort(DateTime date) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[date.weekday - 1];
  }

  int _parseTimeToMinutes(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) return 0;
    try {
      final parts = timeStr.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    } catch (_) {
      return 0;
    }
  }

  String _formatTime12h(String? time24) {
    final int total = _parseTimeToMinutes(time24);
    final int h24 = total ~/ 60;
    final int m = total % 60;
    final int h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final String suffix = h24 >= 12 ? 'PM' : 'AM';
    return '$h12:${m.toString().padLeft(2, '0')} $suffix';
  }

  Future<void> _pickTime() async {
    final int start = _parseTimeToMinutes(_selectedTime ?? '09:00');
    int rounded = ((start + 7) ~/ 15) * 15;
    if (rounded > 1425) rounded = 1425;
    DateTime picked = DateTime(2000, 1, 1, rounded ~/ 60, rounded % 60);

    final bool? confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext, false),
                        child: const Text('Cancel'),
                      ),
                      const Text(
                        'Select time',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext, true),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: false,
                    minuteInterval: 15,
                    initialDateTime: picked,
                    onDateTimeChanged: (DateTime value) => picked = value,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (confirmed != true || !mounted) return;
    setState(() {
      _selectedTime =
          '${picked.hour.toString().padLeft(2, '0')}:'
          '${picked.minute.toString().padLeft(2, '0')}';
      _formError = null;
    });
  }

  int get _getCurrentWeekIndex {
    final today = _dateOnly(DateTime.now());
    final currentWeekStart = _mondayOfWeek(today);
    for (int i = 0; i < weekStarts.length; i++) {
      if (weekStarts[i] == currentWeekStart) {
        return i;
      }
    }
    return 4;
  }

  bool get _isViewingPastWeek {
    return currentWeekIndex < _getCurrentWeekIndex;
  }

  bool get _isViewingCurrentWeek {
    return currentWeekIndex == _getCurrentWeekIndex;
  }

  bool get _canNavigateBackward {
    return currentWeekIndex > 0;
  }

  bool _isDateInPastWeek(DateTime date) {
    final today = _dateOnly(DateTime.now());
    return _dateOnly(date).isBefore(today);
  }

  bool _canEditVisit(Visit visit) {
    final visitDate = _dateOnly(DateTime.parse(visit.date));
    if (_isViewingPastWeek || _isDateInPastWeek(visitDate)) {
      return false;
    }
    return true;
  }

  void _openEditForm(Visit visit) {
    if (!_canEditVisit(visit)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot edit visits from past dates'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _editingVisit = visit;
      _mode = 'edit';
      _selectedDate = _dateOnly(DateTime.parse(visit.date));
      _selectedTime = visit.time ?? '09:00';
      _selectedMarketplace = visit.marketplace;
      _selectedPurpose = visit.purpose;
      _selectedNotes = visit.notes;
      _purposeController.text = visit.purpose ?? '';
      _notesController.text = visit.notes ?? '';
      _formError = null;
      _purposeAutoFilled = false;
    });
  }

  void _openAddForm({DateTime? prefillDate}) {
    if (prefillDate != null && _isDateInPastWeek(prefillDate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot add visits for past dates'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _resetForm();
    setState(() {
      _mode = 'add';
      if (prefillDate != null) _selectedDate = prefillDate;
    });
  }

  void _cancelForm() {
    _resetForm();
    setState(() {
      _mode = null;
      _editingVisit = null;
    });
  }

  Iterable<PlannedVisitSlot> _weekSlots(DateTime? chosen) {
    if (chosen == null) return const <PlannedVisitSlot>[];
    final DateTime weekStart = _mondayOfWeek(chosen);
    final DateTime weekEnd = weekStart.add(const Duration(days: 6));
    return _allVisits
        .where((Visit visit) {
          final DateTime? d = DateTime.tryParse(visit.date);
          if (d == null) return false;
          final DateTime day = _dateOnly(d);
          return !day.isBefore(weekStart) && !day.isAfter(weekEnd);
        })
        .map(
          (Visit visit) => PlannedVisitSlot(
            id: visit.id,
            marketplace: visit.marketplace,
            date: visit.date,
            time: visit.time,
            status: visit.status,
            progress: visit.progress,
          ),
        );
  }

  Future<bool> _confirmRepeatVisit(String message) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Already planned this week'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Plan anyway'),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _updateFollowUpPurpose() {
    if (_mode != 'add') return;
    if (!_purposeAutoFilled && _purposeController.text.trim().isNotEmpty) {
      return;
    }
    final RepeatVisitResult repeat = checkRepeatVisit(
      selectedDate: _selectedDate,
      selectedMarketplace: _selectedMarketplace,
      existingVisits: _weekSlots(_selectedDate),
    );
    if (repeat.kind == RepeatVisitKind.followUp &&
        repeat.suggestedPurpose != null) {
      _purposeController.text = repeat.suggestedPurpose!;
      _selectedPurpose = repeat.suggestedPurpose;
      _purposeAutoFilled = true;
    } else if (_purposeAutoFilled) {
      _purposeController.clear();
      _selectedPurpose = null;
      _purposeAutoFilled = false;
    }
  }

  String? _validateForm() {
    final Iterable<PlannedVisitSlot> existingVisits = _weekSlots(_selectedDate);

    final int timeMinutes = _parseTimeToMinutes(_selectedTime ?? '09:00');
    if (timeMinutes < 9 * 60 || timeMinutes > 17 * 60) {
      return 'Choose a time between 9:00 AM and 5:00 PM.';
    }

    if ((_selectedPurpose ?? '').length > 200) {
      return 'Purpose is too long (max 200 characters).';
    }
    if ((_selectedNotes ?? '').length > 500) {
      return 'Notes are too long (max 500 characters).';
    }

    return validateVisitPlan(
      selectedDate: _selectedDate,
      selectedMarketplace: _selectedMarketplace,
      selectedPurpose: _selectedPurpose,
      selectedTime: _selectedTime,
      existingVisits: existingVisits,
      editingVisitId: _mode == 'edit' ? _editingVisit?.id : null,
      selectedNotes: _selectedNotes,
    );
  }

  Future<void> _savePlan() async {
    if (_savingPlan) return;
    String? error = _validateForm();
    if (error != null && context.read<ConnectivityProvider>().isOnline) {
      setState(() => _savingPlan = true);
      try {
        await fetchSchedule(
          source: Source.server,
        ).timeout(const Duration(seconds: 5));
      } catch (_) {}
      if (!mounted) return;
      setState(() => _savingPlan = false);
      error = _validateForm();
    }
    if (error != null) {
      setState(() => _formError = error);
      return;
    }

    final RepeatVisitResult repeat = checkRepeatVisit(
      selectedDate: _selectedDate,
      selectedMarketplace: _selectedMarketplace,
      existingVisits: _weekSlots(_selectedDate),
      editingVisitId: _mode == 'edit' ? _editingVisit?.id : null,
    );
    final Visit? editing = _mode == 'edit' ? _editingVisit : null;
    final bool targetChanged =
        editing == null ||
        editing.marketplace.trim().toLowerCase() !=
            (_selectedMarketplace ?? '').trim().toLowerCase() ||
        editing.date != _dateString(_selectedDate!);
    if (targetChanged && repeat.kind == RepeatVisitKind.warn) {
      setState(() => _savingPlan = true);
      final bool proceed = await _confirmRepeatVisit(repeat.message ?? '');
      if (!mounted) return;
      if (!proceed) {
        setState(() => _savingPlan = false);
        return;
      }
    }

    setState(() {
      _savingPlan = true;
      _formError = null;
    });
    try {
      final bool queued;
      if (_mode == 'edit' && _editingVisit != null) {
        final updated = Visit(
          id: _editingVisit!.id,
          marketplace: _selectedMarketplace!,
          time: _selectedTime ?? '09:00',
          purpose: _selectedPurpose!,
          notes: _selectedNotes ?? '',
          date: _dateString(_selectedDate!),
        );
        queued = await updateVisit(updated);
      } else {
        final newVisit = Visit(
          id: _draftVisitId ??= DateTime.now().millisecondsSinceEpoch
              .toString(),
          marketplace: _selectedMarketplace!,
          time: _selectedTime ?? '09:00',
          purpose: _selectedPurpose!,
          notes: _selectedNotes ?? '',
          date: _dateString(_selectedDate!),
        );
        queued = await addVisit(newVisit);
      }

      if (!mounted) return;
      _resetForm();
      setState(() => _mode = null);
      if (queued) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Visit saved on this phone. It will be sent when you are online. If the server refuses it, it stays on this phone under Needs attention on Home.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _formError =
            'Visit could not be saved. Check your connection and try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _savingPlan = false);
      }
    }
  }

  void _resetForm() {
    setState(() {
      _editingVisit = null;
      _draftVisitId = null;
      _selectedDate = null;
      _selectedTime = '09:00';
      _selectedMarketplace = null;
      _selectedPurpose = null;
      _selectedNotes = null;
      _formError = null;
      _purposeAutoFilled = false;
      _purposeController.clear();
      _notesController.clear();
    });
  }

  bool get _hasMetWeeklyGoal {
    if (currentWeek == null) return false;
    final today = _dateOnly(DateTime.now());
    final weekStart = _mondayOfWeek(today);
    final weekEnd = weekStart.add(const Duration(days: 6));

    for (var dateSchedule in currentWeek!.dates) {
      final date = _dateOnly(dateSchedule.date);
      if (!date.isBefore(weekStart) && !date.isAfter(weekEnd)) {
        if (dateSchedule.visits.isNotEmpty) return true;
      }
    }
    return false;
  }

  int get totalVisits {
    if (currentWeek == null) return 0;
    return currentWeek!.dates.fold(
      0,
      (total, date) => total + date.visits.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showFallbackBar =
        _loading || _loadError != null || currentWeek == null;
    return PopScope<void>(
      canPop: _mode == null,
      onPopInvokedWithResult: (bool didPop, void _) {
        if (!didPop) _cancelForm();
      },
      child: showFallbackBar
          ? ScootPhoneScaffold(
              appBar: ScootPhoneAppBar(
                title: 'Planner',
                onBack: () => Navigator.of(context).maybePop(),
              ),
              body: PhoneStateBody(
                loading: _loading,
                error: !_loading,
                errorTitle: 'Could not load planner',
                onRetry: _loadInitialData,
              ),
            )
          : _mode != null
          ? _buildFormView()
          : _buildMainView(),
    );
  }

  Widget _buildMainView() {
    final ScootColors c = ScootColors.of(context);
    final bool goalMet = _isViewingCurrentWeek && _hasMetWeeklyGoal;
    final ScootTone goalTone = _isViewingPastWeek
        ? ScootTone.neutral
        : goalMet
        ? ScootTone.success
        : ScootTone.warning;
    final ScootToneColors goal = c.tone(goalTone);
    return Scaffold(
      backgroundColor: c.page,
      appBar: ScootPhoneAppBar(
        title: 'Sales Planner',
        subtitle: 'Organize your marketplace visits',
        onBack: () => Navigator.of(context).maybePop(),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: goal.background,
                border: Border.all(color: goal.border),
                borderRadius: ScootRadius.cardAll,
              ),
              child: Row(
                children: [
                  Icon(
                    _isViewingPastWeek
                        ? ScootIcons.history
                        : goalMet
                        ? ScootIcons.success
                        : ScootIcons.info,
                    color: goal.foreground,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Weekly Market Goal',
                          style: ScootType.smallStrong.copyWith(
                            color: goal.foreground,
                          ),
                        ),
                        Text(
                          _isViewingPastWeek
                              ? 'Past week'
                              : goalMet
                              ? 'You have a visit planned this week.'
                              : 'Remember to visit at least one marketplace this week.',
                          style: ScootType.small.copyWith(color: goal.noteText),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: _buildListTab()),
        ],
      ),
      bottomNavigationBar: _isViewingPastWeek
          ? null
          : ScootPrimaryActionBar(
              label: 'Add Visit',
              icon: ScootIcons.add,
              aboveHomeIndicator: true,
              onPressed: () => _openAddForm(),
            ),
    );
  }

  Widget _buildListTab() {
    if (currentWeek == null) return const SizedBox.shrink();

    final today = _dateOnly(DateTime.now());
    final currentWeekStart = _mondayOfWeek(today);
    final isCurrentWeek = currentWeek!.startDate == currentWeekStart;

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AppIconButton(
                tooltip: 'Previous week',
                icon: Icons.chevron_left,
                color: _canNavigateBackward
                    ? AppColors.greenSolid
                    : AppColors.textSecondary.withValues(alpha: 0.3),
                onPressed: _canNavigateBackward
                    ? () {
                        setState(() => currentWeekIndex--);
                        fetchSchedule();
                      }
                    : null,
              ),

              Column(
                children: [
                  Text(
                    _weekRangeLabel(currentWeek!),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (_isViewingPastWeek)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Past Week',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textAmber,
                        ),
                      ),
                    )
                  else if (!isCurrentWeek)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => currentWeekIndex = _getCurrentWeekIndex);
                        fetchSchedule();
                      },
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: Center(
                          widthFactor: 1,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.greenSolid,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Go to Today',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.greenSolid.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'This Week',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                ],
              ),

              AppIconButton(
                tooltip: 'Next week',
                icon: Icons.chevron_right,
                color: AppColors.greenSolid,
                onPressed: () {
                  _ensureEnoughWeeks();
                  setState(() => currentWeekIndex++);
                  fetchSchedule();
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        Expanded(
          child: totalVisits == 0
              ? _buildEmptyWeekState()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: currentWeek!.dates.map((dateSchedule) {
                    final dateKey = _dateString(dateSchedule.date);
                    final isExpanded = _expandedDates[dateKey] ?? false;
                    final hasVisits = dateSchedule.visits.isNotEmpty;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildCollapsibleDaySection(
                        dateSchedule,
                        isExpanded,
                        hasVisits,
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyWeekState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.greenSolid.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.calendar_today,
              size: 40,
              color: AppColors.greenSolid.withValues(alpha: 0.3),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No plans this week',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textGrey,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isViewingPastWeek
                ? 'This is a past week.'
                : 'Tap the + button to add your first visit.',
            style: TextStyle(fontSize: 14, color: AppColors.textGrey),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsibleDaySection(
    DateSchedule dateSchedule,
    bool isExpanded,
    bool hasVisits,
  ) {
    final dateKey = _dateString(dateSchedule.date);
    final isPast = _dateOnly(
      dateSchedule.date,
    ).isBefore(_dateOnly(DateTime.now()));
    final today = _dateOnly(DateTime.now());
    final isToday = _dateOnly(dateSchedule.date) == today;

    return Container(
      decoration: BoxDecoration(
        color: isToday
            ? AppColors.primary.withValues(alpha: 0.08)
            : Colors.white,
        border: Border.all(
          color: isToday
              ? AppColors.primary.withValues(alpha: 0.3)
              : AppColors.inputBorder,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: hasVisits
                ? () {
                    setState(() {
                      _expandedDates[dateKey] = !isExpanded;
                    });
                  }
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _dayNameShort(dateSchedule.date),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textGrey,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              dateSchedule.date.day.toString(),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isToday
                                    ? AppColors.primary
                                    : AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _month(dateSchedule.date.month),
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textGrey,
                              ),
                            ),
                          ],
                        ),
                        if (isToday)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(
                                  alpha: 0.15,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'Today',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (hasVisits)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${dateSchedule.visits.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                        )
                      else
                        Text(
                          'No visits',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textGrey,
                          ),
                        ),
                      const SizedBox(height: 4),
                      if (hasVisits)
                        Icon(
                          isExpanded ? Icons.expand_less : Icons.expand_more,
                          color: AppColors.primary,
                          size: 20,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          if (hasVisits && isExpanded)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: AppColors.inputBorder.withValues(alpha: 0.5),
                  ),
                ),
              ),
              child: Column(
                children: dateSchedule.visits.asMap().entries.map((entry) {
                  final index = entry.key;
                  final visit = entry.value;
                  final isLast = index == dateSchedule.visits.length - 1;
                  final canEdit = _canEditVisit(visit);

                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildCompactVisitTile(visit, canEdit),
                      ),
                      if (!isLast)
                        Divider(
                          height: 1,
                          color: AppColors.inputBorder.withValues(alpha: 0.3),
                          indent: 16,
                          endIndent: 16,
                        ),
                    ],
                  );
                }).toList(),
              ),
            ),

          if (!_isViewingPastWeek &&
              !isPast &&
              (!hasVisits || (hasVisits && isExpanded)))
            GestureDetector(
              onTap: () =>
                  _openAddForm(prefillDate: _dateOnly(dateSchedule.date)),
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                constraints: const BoxConstraints(minHeight: 44),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add, size: 16, color: AppColors.primary),
                      const SizedBox(width: 6),
                      Text(
                        'Add visit',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCompactVisitTile(Visit visit, bool canEdit) {
    return GestureDetector(
      onTap: () => _showVisitBottomSheet(visit, canEdit),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        visit.time ?? 'TBD',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        visit.marketplace,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (canEdit)
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      _openEditForm(visit);
                    } else if (value == 'delete') {
                      confirmAndDeleteVisit(visit.id);
                    }
                  },
                  itemBuilder: (BuildContext context) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit, size: 18),
                          SizedBox(width: 8),
                          Text('Edit'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, size: 18, color: Colors.red),
                          SizedBox(width: 8),
                          Text(
                            'Delete',
                            style: TextStyle(color: AppColors.textRed),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              else
                Icon(
                  Icons.lock_outline,
                  size: 20,
                  color: AppColors.textSecondary.withValues(alpha: 0.4),
                ),
            ],
          ),
          if (visit.purpose != null && visit.purpose!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.flag_outlined,
                  size: 12,
                  color: AppColors.textSecondary.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    visit.purpose!,
                    style: TextStyle(fontSize: 12, color: AppColors.textGrey),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _showVisitBottomSheet(Visit visit, bool canEdit) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 14,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        visit.time ?? 'TBD',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _displayDateString(DateTime.parse(visit.date)),
                  style: TextStyle(fontSize: 13, color: AppColors.textGrey),
                ),
              ],
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Icon(
                  Icons.location_on,
                  size: 18,
                  color: AppColors.primary.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    visit.marketplace,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),

            if (visit.purpose != null && visit.purpose!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.flag_outlined,
                    size: 14,
                    color: AppColors.textSecondary.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      visit.purpose!,
                      style: TextStyle(fontSize: 13, color: AppColors.textGrey),
                    ),
                  ),
                ],
              ),
            ],

            if (visit.notes != null && visit.notes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.tagZone,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.note,
                      size: 14,
                      color: AppColors.textSecondary.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        visit.notes!,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textGrey,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),

            if (canEdit)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openEditForm(visit);
                      },
                      icon: Icon(
                        Icons.edit_outlined,
                        size: 16,
                        color: AppColors.primary,
                      ),
                      label: Text(
                        'Edit',
                        style: TextStyle(color: AppColors.primary),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppColors.primary),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        confirmAndDeleteVisit(visit.id);
                      },
                      icon: Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: AppColors.danger,
                      ),
                      label: Text(
                        'Delete',
                        style: TextStyle(color: AppColors.textRed),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: AppColors.danger.withValues(alpha: 0.5),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.textSecondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 18,
                        color: AppColors.textSecondary.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Past date - View Only',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textGrey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _weekRangeLabel(WeekSchedule week) {
    final start = week.startDate;
    final end = start.add(const Duration(days: 6));
    if (start.month == end.month) {
      return '${start.day} – ${end.day} ${_month(start.month)} ${start.year}';
    }
    return '${start.day} ${_month(start.month)} – ${end.day} ${_month(end.month)} ${start.year}';
  }

  Widget _buildFormView() {
    return PlannerVisitForm(
      isEditing: _mode == 'edit',
      dateLabel: _selectedDate == null
          ? null
          : _displayDateString(_selectedDate!),
      dayName: _selectedDate == null ? null : _dayName(_selectedDate!),
      timeLabel: _formatTime12h(_selectedTime ?? '09:00'),
      marketplaces: _marketplaces,
      retailerLoadError: _retailerLoadError,
      selectedMarketplace: _selectedMarketplace,
      purposeController: _purposeController,
      notesController: _notesController,
      purposeFormatters: [_SafeTextFormatter(maxLength: 200)],
      notesFormatters: [_SafeTextFormatter(maxLength: 500)],
      saving: _savingPlan,
      formError: _formError,
      onBack: _cancelForm,
      onPickDate: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _selectedDate ?? DateTime.now(),
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 180)),
        );
        if (picked != null) {
          setState(() {
            _selectedDate = _dateOnly(picked);
            _formError = null;
            _updateFollowUpPurpose();
          });
        }
      },
      onPickTime: _pickTime,
      onMarketplaceChanged: (value) => setState(() {
        _selectedMarketplace = value;
        _formError = null;
        _updateFollowUpPurpose();
      }),
      onPurposeChanged: (value) {
        _selectedPurpose = value;
        _purposeAutoFilled = false;
        setState(() => _formError = null);
      },
      onNotesChanged: (value) => _selectedNotes = value,
      onSave: _savePlan,
    );
  }
}
