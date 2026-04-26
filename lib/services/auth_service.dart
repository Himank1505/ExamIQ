import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  final FirebaseAuth      _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db   = FirebaseFirestore.instance;

  User?   get currentUser      => _auth.currentUser;
  String? get currentUid       => _auth.currentUser?.uid;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ── Login ──────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    String? expectedRole,
  }) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email:    email.trim(),
        password: password.trim(),
      );
      final role = await getUserRole(cred.user!.uid);
      if (expectedRole != null && expectedRole.isNotEmpty && role != expectedRole) {
        await _auth.signOut();
        return {
          'success': false,
          'error': 'This account is registered as ${role.toUpperCase()}, not ${expectedRole.toUpperCase()}.',
        };
      }
      return {'success': true, 'role': role, 'uid': cred.user!.uid};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'error': _authError(e.code)};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Register student ───────────────────────────────────────────────────────
  Future<Map<String, dynamic>> registerStudent({
    required String email,
    required String password,
    required String name,
    required String college,
    required String course,
    required String rollNumber,
    required String aadhaarNumber,
  }) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email:    email.trim(),
        password: password.trim(),
      );
      await _db.collection('students').doc(cred.user!.uid).set({
        'student_id':        cred.user!.uid,
        'name':              name.trim(),
        'email':             email.trim(),
        'college':           college.trim(),
        'course':            course.trim(),
        'roll_number':       rollNumber.trim(),
        'aadhaar_number':    aadhaarNumber.trim(),
        'role':              'student',
        'enrollment_status': 'pending',
        'created_at':        FieldValue.serverTimestamp(),
      });
      return {'success': true, 'uid': cred.user!.uid};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'error': _authError(e.code)};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Register teacher ───────────────────────────────────────────────────────
  Future<Map<String, dynamic>> registerTeacher({
    required String email,
    required String password,
    required String name,
    required String college,
    required String department,
    required String employeeId,
  }) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email:    email.trim(),
        password: password.trim(),
      );
      await _db.collection('teachers').doc(cred.user!.uid).set({
        'teacher_id':   cred.user!.uid,
        'name':         name.trim(),
        'email':        email.trim(),
        'college':      college.trim(),
        'department':   department.trim(),
        'employee_id':  employeeId.trim(),
        'role':         'teacher',
        'created_at':   FieldValue.serverTimestamp(),
      });
      return {'success': true, 'uid': cred.user!.uid};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'error': _authError(e.code)};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Get user role ──────────────────────────────────────────────────────────
  Future<String> getUserRole(String uid) async {
    try {
      final studentDoc = await _db.collection('students').doc(uid).get();
      if (studentDoc.exists) return 'student';
      final teacherDoc = await _db.collection('teachers').doc(uid).get();
      if (teacherDoc.exists) return 'teacher';
      return 'student';
    } catch (_) {
      return 'student';
    }
  }

  // ── Get current user data ──────────────────────────────────────────────────
  Future<Map<String, dynamic>?> getCurrentUserData() async {
    try {
      final uid = currentUid;
      if (uid == null) return null;
      final role       = await getUserRole(uid);
      final collection = role == 'teacher' ? 'teachers' : 'students';
      final doc        = await _db.collection(collection).doc(uid).get();
      return doc.exists ? {'id': doc.id, ...doc.data()!} : null;
    } catch (_) {
      return null;
    }
  }

  // ── Logout ─────────────────────────────────────────────────────────────────
  Future<void> logout() async => await _auth.signOut();

  // ── Friendly error messages ────────────────────────────────────────────────
  String _authError(String code) {
    switch (code) {
      case 'user-not-found':       return 'No account found with this email.';
      case 'wrong-password':       return 'Incorrect password.';
      case 'email-already-in-use': return 'An account already exists with this email.';
      case 'weak-password':        return 'Password must be at least 6 characters.';
      case 'invalid-email':        return 'Please enter a valid email address.';
      case 'too-many-requests':    return 'Too many attempts. Please try again later.';
      default:                     return 'Something went wrong. Please try again.';
    }
  }
}
