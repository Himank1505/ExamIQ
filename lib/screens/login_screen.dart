import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController    = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey            = GlobalKey<FormState>();
  final _authService        = AuthService();

  bool    _isLoading    = false;
  bool    _obscurePass  = true;
  String  _selectedRole = 'student';
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });

    final result = await _authService.login(
      email:    _emailController.text,
      password: _passwordController.text,
      expectedRole: _selectedRole,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] == true) {
      final role = result['role'];
      if (role == 'teacher') {
        Navigator.pushReplacementNamed(context, '/teacher-dashboard');
      } else {
        Navigator.pushReplacementNamed(context, '/student-dashboard');
      }
    } else {
      setState(() => _errorMessage = result['error']);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 60),
              Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFF534AB7),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.verified_user_rounded,
                    color: Colors.white, size: 44),
              ),
              const SizedBox(height: 20),
              const Text('ExamIQ',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold,
                      color: Color(0xFF534AB7))),
              const Text('Secure exam integrity platform',
                  style: TextStyle(fontSize: 14, color: Colors.grey)),
              const SizedBox(height: 48),
              _buildRoleSwitcher(),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Enter your email';
                        if (!v.contains('@')) return 'Enter a valid email';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePass,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePass
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () =>
                              setState(() => _obscurePass = !_obscurePass),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Enter your password';
                        if (v.length < 6) return 'Password too short';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    if (_errorMessage != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFCEBEB),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFF09595)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline,
                                color: Color(0xFFA32D2D), size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_errorMessage!,
                                style: const TextStyle(
                                    color: Color(0xFFA32D2D), fontSize: 13))),
                          ],
                        ),
                      ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _login,
                      child: _isLoading
                          ? const SizedBox(height: 20, width: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                          : const Text('Login',
                          style: TextStyle(fontSize: 16,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text("Don't have an account? ",
                            style: TextStyle(color: Colors.grey)),
                        GestureDetector(
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(
                                  builder: (_) => RegisterScreen(
                                    initialRole: _selectedRole,
                                  ))),
                          child: const Text('Register',
                              style: TextStyle(color: Color(0xFF534AB7),
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEEDFE),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFAFA9EC)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Demo credentials',
                        style: TextStyle(fontWeight: FontWeight.w600,
                            color: Color(0xFF3C3489), fontSize: 13)),
                    SizedBox(height: 6),
                    Text(
                      'Student:  student@examiq.edu / test123\nTeacher:  teacher@examiq.edu / test123',
                      style: TextStyle(color: Color(0xFF534AB7),
                          fontSize: 12, fontFamily: 'Courier'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
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
          _roleChip('student', 'Student'),
          _roleChip('teacher', 'Teacher'),
        ],
      ),
    );
  }

  Widget _roleChip(String value, String label) {
    final selected = _selectedRole == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedRole = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF534AB7) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '$label Sign In',
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
}
