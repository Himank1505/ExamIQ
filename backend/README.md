# ExamIQ Local Backend

This project now includes a local backend at `backend/server.dart` for:

- `GET /health`
- `POST /api/enroll`
- `POST /api/verify`
- `POST /api/monitor`
- `POST /api/generate-report`
- `POST /api/send-report-email`

## Run

From project root:

```bash
dart run backend/server.dart
```

Server URL:

- `http://127.0.0.1:8000`

## Notes

- Enrollment vectors are stored locally in `backend/data/enrollments.json`.
- Duplicate-face enrollment across different student IDs is blocked.
- Verify endpoint returns strict identity fields used by the Flutter app (`cleared`, `verified`, `face_match_score`, `matched_student_id`, etc.).
