import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/behavioral_tracker.dart';
import 'enrollment_screen.dart';

class RegisterScreen extends StatefulWidget {
  final String initialRole;

  const RegisterScreen({
    super.key,
    this.initialRole = 'student',
  });

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey         = GlobalKey<FormState>();
  final _authService     = AuthService();
  final _behavioralTracker = BehavioralTracker();
  final _nameController     = TextEditingController();
  final _emailController    = TextEditingController();
  final _passwordController = TextEditingController();
  final _rollController     = TextEditingController();
  final _aadhaarController  = TextEditingController();
  final _employeeIdController = TextEditingController();

  late String _selectedRole;
  String  _selectedCollege = 'Pune University';
  String  _selectedCourse  = 'B.Tech Computer Science';
  String  _selectedDepartment = 'Computer Science';
  bool    _isLoading       = false;
  bool    _obscurePass     = true;
  String? _errorMessage;

  final List<String> _colleges = [
    'Pune University','COEP Pune','VIT Pune','MIT Pune',
    'Symbiosis Institute of Technology',
  ];
  final List<String> _courses = [
    'B.Tech Computer Science','B.Tech Information Technology',
    'B.Tech Electronics','B.Tech Mechanical','B.Tech Civil',
  ];
  final List<String> _departments = [
    'Computer Science', 'Information Technology', 'Electronics',
    'Mechanical', 'Civil', 'Mathematics', 'Physics',
  ];

  @override
  void initState() {
    super.initState();
    _selectedRole = widget.initialRole;
    _attachBehavioralTrackers();
  }

  void _attachBehavioralTrackers() {
    for (final ctrl in [
      _nameController,
      _emailController,
      _passwordController,
      _rollController,
      _aadhaarController,
      _employeeIdController,
    ]) {
      _trackController(ctrl);
    }
  }

  void _trackController(TextEditingController ctrl) {
    String prev = '';
    ctrl.addListener(() {
      final curr = ctrl.text;
      if (curr == prev) return;
      _behavioralTracker.recordKeystroke(isDeletion: curr.length < prev.length);
      prev = curr;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _rollController.dispose();
    _aadhaarController.dispose();
    _employeeIdController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });

    Map<String, dynamic> result;
    if (_selectedRole == 'student') {
      result = await _authService.registerStudent(
        email: _emailController.text,
        password: _passwordController.text,
        name: _nameController.text,
        college: _selectedCollege,
        course: _selectedCourse,
        rollNumber: _rollController.text,
        aadhaarNumber: _aadhaarController.text,
      );
    } else {
      result = await _authService.registerTeacher(
        email: _emailController.text,
        password: _passwordController.text,
        name: _nameController.text,
        college: _selectedCollege,
        department: _selectedDepartment,
        employeeId: _employeeIdController.text,
      );
    }

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] == true) {
      if (_selectedRole == 'student') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => EnrollmentScreen(
              studentId: result['uid'],
              initialBehavioralSamples: _behavioralTracker.buildSamples(),
            ),
          ),
        );
      } else {
        Navigator.pushNamedAndRemoveUntil(
          context,
          '/teacher-dashboard',
          (route) => false,
        );
      }
    } else {
      setState(() => _errorMessage = result['error']);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isStudent = _selectedRole == 'student';

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text('Create Account'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildRoleSwitcher(),
                const SizedBox(height: 18),
                Text(
                  isStudent ? 'Student Registration' : 'Teacher Registration',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1a1a2e),
                  ),
                ),
                const Text(
                  'Fill in your details to create an account',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 28),
                _label('Full Name'),
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Rahul Sharma',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) => v == null || v.isEmpty
                      ? 'Enter your full name'
                      : null,
                ),
                const SizedBox(height: 16),
                _label('Email'),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText: 'e.g. user@college.edu',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Enter your email';
                    if (!v.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                _label('Password'),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePass,
                  decoration: InputDecoration(
                    hintText: 'Minimum 6 characters',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePass
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () {
                        setState(() => _obscurePass = !_obscurePass);
                      },
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Enter a password';
                    if (v.length < 6) return 'Minimum 6 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                _label('College'),
                DropdownButtonFormField<String>(
                  initialValue: _selectedCollege,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.school_outlined),
                  ),
                  items: _colleges
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedCollege = v!),
                ),
                const SizedBox(height: 16),
                if (isStudent) ...[
                  _label('Roll Number'),
                  TextFormField(
                    controller: _rollController,
                    decoration: const InputDecoration(
                      hintText: 'e.g. PU-2024-0421',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    validator: (v) {
                      if (_selectedRole != 'student') return null;
                      return v == null || v.isEmpty
                          ? 'Enter your roll number'
                          : null;
                    },
                  ),
                  const SizedBox(height: 16),
                  _label('Course'),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedCourse,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.book_outlined),
                    ),
                    items: _courses
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedCourse = v!),
                  ),
                  const SizedBox(height: 16),
                  _label('Aadhaar Number'),
                  TextFormField(
                    controller: _aadhaarController,
                    keyboardType: TextInputType.number,
                    maxLength: 12,
                    decoration: const InputDecoration(
                      hintText: '12-digit Aadhaar number',
                      counterText: '',
                      prefixIcon: Icon(Icons.credit_card_outlined),
                    ),
                    validator: (v) {
                      if (_selectedRole != 'student') return null;
                      final value = (v ?? '').trim();
                      if (value.isEmpty) return 'Enter Aadhaar number';
                      if (!RegExp(r'^\d{12}$').hasMatch(value)) {
                        return 'Aadhaar must be exactly 12 digits';
                      }
                      return null;
                    },
                  ),
                ] else ...[
                  _label('Department'),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedDepartment,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.account_tree_outlined),
                    ),
                    items: _departments
                        .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedDepartment = v!),
                  ),
                  const SizedBox(height: 16),
                  _label('Employee ID'),
                  TextFormField(
                    controller: _employeeIdController,
                    decoration: const InputDecoration(
                      hintText: 'e.g. FAC-1024',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    validator: (v) {
                      if (_selectedRole != 'teacher') return null;
                      return v == null || v.isEmpty
                          ? 'Enter employee ID'
                          : null;
                    },
                  ),
                ],
                const SizedBox(height: 20),
                if (_errorMessage != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFCEBEB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF09595)),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Color(0xFFA32D2D),
                        fontSize: 13,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE1F5EE),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF5DCAA5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Color(0xFF085041),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isStudent
                              ? 'After student registration, face enrollment (with liveness) will start automatically.'
                              : 'Teacher account will be created directly in Firebase and opened in teacher dashboard.',
                          style: const TextStyle(
                            color: Color(0xFF085041),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isLoading ? null : _register,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          isStudent
                              ? 'Register & Continue to Face Enrollment'
                              : 'Register Teacher Account',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Already have an account? ',
                      style: TextStyle(color: Colors.grey),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Text(
                        'Sign In',
                        style: TextStyle(
                          color: Color(0xFF534AB7),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoleSwitcher() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFEEEDFE),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _roleChip('student', 'Student Sign Up'),
          _roleChip('teacher', 'Teacher Sign Up'),
        ],
      ),
    );
  }

  Widget _roleChip(String value, String label) {
    final selected = _selectedRole == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedRole = value;
            _errorMessage = null;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF534AB7) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFF534AB7),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF444441),
          ),
        ),
      );
}
