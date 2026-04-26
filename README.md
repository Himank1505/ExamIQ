# ExamIQ App

ExamIQ is an AI-powered exam integrity platform built with Flutter. It combines student authentication, face-based enrollment and verification, exam monitoring, and teacher-side reporting in a single cross-platform application.

## What It Does

- Student login and registration with Firebase Authentication
- Face enrollment and identity verification before exams
- Ongoing exam monitoring with integrity checks
- Teacher dashboard for managing exams and reviewing outcomes
- Report generation and report-sharing flow after exam completion
- Local Dart backend for enrollment, verification, and monitoring APIs

## Tech Stack

- Flutter for the app experience
- Firebase Authentication and Firestore for user management and app data
- Dart HTTP backend for proctoring-related API endpoints
- Camera and image-processing packages for face capture workflows

## Project Structure

- `lib/` Flutter app screens, services, and UI flows
- `backend/` Local Dart backend used for enrollment and monitoring endpoints
- `assets/` Static assets used by the app
- `web/`, `ios/`, `macos/`, `windows/` Platform-specific Flutter targets

## Getting Started

### Prerequisites

- Flutter SDK
- Dart SDK
- Firebase project configuration

### Run The Flutter App

```bash
flutter pub get
flutter run
```

### Run The Local Backend

```bash
dart run backend/server.dart
```

The backend starts on `http://0.0.0.0:8000` and exposes endpoints for health checks, enrollment, verification, monitoring, and report generation.

## Notes

- Enrollment data is stored locally by the backend in `backend/data/`, which is ignored by git.
- Firebase client configuration is included for app setup and should match the intended Firebase project for deployment.
