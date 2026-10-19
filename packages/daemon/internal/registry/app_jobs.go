package registry

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
	_ "time/tzdata"
)

type AppScheduleSpec struct {
	ID               string `json:"id,omitempty"`
	ExpectedRevision *int64 `json:"expectedRevision,omitempty"`
	Name             string `json:"name"`
	RunAt            string `json:"runAt,omitempty"`
	IntervalSeconds  int    `json:"intervalSeconds,omitempty"`
	LocalTime        string `json:"localTime,omitempty"`
	TimeZone         string `json:"timeZone,omitempty"`
	Weekdays         []int  `json:"weekdays,omitempty"`
	Command          string `json:"command,omitempty"`
	Title            string `json:"title,omitempty"`
	Body             string `json:"body,omitempty"`
	Enabled          *bool  `json:"enabled,omitempty"`
}

type AppSchedule struct {
	AppScheduleSpec
	AppID       string `json:"appId"`
	Revision    int64  `json:"revision"`
	Active      bool   `json:"active"`
	NextRunAt   string `json:"nextRunAt,omitempty"`
	LastRunAt   string `json:"lastRunAt,omitempty"`
	State       string `json:"state"`
	LastError   string `json:"lastError,omitempty"`
	Occurrence  string `json:"occurrence,omitempty"`
	RetryAt     string `json:"retryAt,omitempty"`
	Attempts    int    `json:"attempts"`
	CommandDone bool   `json:"commandDone,omitempty"`
	LeaseUntil  string `json:"leaseUntil,omitempty"`
}

func (job AppSchedule) Next(after time.Time) (time.Time, error) {
	if job.LocalTime != "" {
		if len(job.LocalTime) != 5 || job.TimeZone == "" || job.TimeZone == "Local" {
			return time.Time{}, invalid("calendar schedules need localTime HH:mm and an IANA timeZone")
		}
		clock, err := time.Parse("15:04", job.LocalTime)
		if err != nil {
			return time.Time{}, invalid("localTime must be HH:mm")
		}
		zone, err := time.LoadLocation(job.TimeZone)
		if err != nil {
			return time.Time{}, invalid("use an IANA timeZone such as Europe/London")
		}
		local := after.In(zone)
		for offset := 0; offset < 8; offset++ {
			date := local.AddDate(0, 0, offset)
			candidate := time.Date(date.Year(), date.Month(), date.Day(), clock.Hour(), clock.Minute(), 0, 0, zone)
			allowed := len(job.Weekdays) == 0
			for _, day := range job.Weekdays {
				if day == int(candidate.Weekday()) {
					allowed = true
				}
			}
			if allowed && candidate.After(after) {
				return candidate.UTC(), nil
			}
		}
		return time.Time{}, invalid("no next schedule occurrence")
	}
	if job.IntervalSeconds > 0 {
		duration := time.Duration(job.IntervalSeconds) * time.Second
		base, err := time.Parse(time.RFC3339Nano, job.NextRunAt)
		if err != nil {
			base = after
		}
		if !base.After(after) {
			base = after.Add(duration - after.Sub(base)%duration)
		}
		return base.UTC(), nil
	}
	return time.Time{}, nil
}

func (st *Store) AppSchedules(appID string) ([]AppSchedule, error) {
	rows, err := st.db.Query("SELECT data FROM app_jobs WHERE app_id=? ORDER BY id", appID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AppSchedule{}
	for rows.Next() {
		var raw []byte
		var job AppSchedule
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(raw, &job); err != nil {
			return nil, err
		}
		out = append(out, job)
	}
	return out, rows.Err()
}

func readAppJob(q queryer, id string) (AppSchedule, error) {
	var raw []byte
	var job AppSchedule
	err := q.QueryRow("SELECT data FROM app_jobs WHERE id=?", id).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return job, ErrNotFound
	}
	if err != nil {
		return job, err
	}
	err = json.Unmarshal(raw, &job)
	return job, err
}

func saveAppJob(tx *sql.Tx, job AppSchedule) error {
	raw, err := json.Marshal(job)
	if err != nil {
		return err
	}
	_, err = tx.Exec("INSERT INTO app_jobs VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", job.ID, job.AppID, raw)
	return err
}

func (st *Store) SaveAppSchedule(appID string, spec AppScheduleSpec) (AppSchedule, error) {
	var job AppSchedule
	spec.Name = strings.TrimSpace(spec.Name)
	spec.Command = strings.TrimSpace(spec.Command)
	spec.TimeZone = strings.TrimSpace(spec.TimeZone)
	if len(spec.Weekdays) > 7 {
		return job, invalid("choose up to seven weekdays")
	}
	spec.Weekdays = slices.Compact(slices.Sorted(slices.Values(spec.Weekdays)))
	if spec.Name == "" || len(spec.Name) > 120 || len(spec.Command) > 8192 || strings.ContainsRune(spec.Command, 0) || len(spec.Title) > 256 || len(spec.Body) > 2048 || (spec.Command == "" && spec.Title == "" && spec.Body == "") {
		return job, invalid("a schedule needs a name and a command or notification message")
	}
	if spec.IntervalSeconds < 0 || spec.IntervalSeconds > 31536000 || (spec.IntervalSeconds > 0 && spec.IntervalSeconds < 60) {
		return job, invalid("intervalSeconds must be between 60 and 31536000")
	}
	if spec.IntervalSeconds > 0 && spec.LocalTime != "" {
		return job, invalid("choose an interval or a local clock time")
	}
	if spec.LocalTime == "" && (spec.TimeZone != "" || len(spec.Weekdays) > 0) {
		return job, invalid("timeZone and weekdays require localTime")
	}
	for _, day := range spec.Weekdays {
		if day < 0 || day > 6 {
			return job, invalid("weekdays range from 0 (Sunday) to 6")
		}
	}
	if spec.ID == "" {
		sum := sha256.Sum256([]byte(appID + "\x00" + spec.Name))
		spec.ID = "job-" + hex.EncodeToString(sum[:16])
	}
	if !validID(spec.ID) {
		return job, invalid("invalid schedule id")
	}
	tx, err := st.db.Begin()
	if err != nil {
		return job, err
	}
	defer tx.Rollback()
	app, err := readApp(tx, appID)
	if err != nil {
		return job, err
	}
	if app.Archived {
		return job, ErrDeleted
	}
	project, _, err := record(tx, "projects", app.ProjectID)
	if err != nil {
		return job, err
	}
	if project == nil {
		return job, ErrNotFound
	}
	if err = checkChatProject(tx, project); err != nil {
		return job, err
	}
	old, err := readAppJob(tx, spec.ID)
	if err == nil {
		if old.AppID != appID || spec.ExpectedRevision == nil || *spec.ExpectedRevision != old.Revision {
			return old, ErrConflict
		}
		if old.State == "running" {
			return old, invalid("this schedule is running; retry the edit after it finishes")
		}
		job = old
	} else if !errors.Is(err, ErrNotFound) {
		return job, err
	} else {
		var count int
		if err = tx.QueryRow("SELECT count(*) FROM app_jobs").Scan(&count); err != nil {
			return job, err
		}
		if count >= 512 {
			return job, invalid("this computer has reached its schedule limit")
		}
	}
	job.AppScheduleSpec = spec
	job.ExpectedRevision = nil
	job.Enabled = nil
	job.AppID = appID
	job.Revision++
	job.State = "scheduled"
	job.LastError = ""
	job.Occurrence = ""
	job.RetryAt = ""
	job.Attempts = 0
	job.CommandDone = false
	job.LeaseUntil = ""
	job.NextRunAt = ""
	job.Active = spec.Enabled == nil || *spec.Enabled
	now := time.Now().UTC()
	// Toggling a recurring job retains its next future occurrence, rather than
	// replaying the original start date or shifting its interval on every edit.
	if old.ID != "" && spec.RunAt == old.RunAt && spec.IntervalSeconds == old.IntervalSeconds && spec.LocalTime == old.LocalTime && spec.TimeZone == old.TimeZone && slices.Equal(spec.Weekdays, old.Weekdays) && (spec.IntervalSeconds > 0 || spec.LocalTime != "") {
		job.NextRunAt = old.NextRunAt
		if at, err := time.Parse(time.RFC3339Nano, job.NextRunAt); err != nil || !at.After(now) {
			next, err := job.Next(now)
			if err != nil {
				return job, err
			}
			job.NextRunAt = next.Format(time.RFC3339Nano)
		}
	} else if spec.RunAt != "" {
		at, err := time.Parse(time.RFC3339Nano, spec.RunAt)
		if err != nil {
			return job, invalid("runAt must be an ISO timestamp with UTC or an explicit offset")
		}
		job.NextRunAt = at.UTC().Format(time.RFC3339Nano)
	} else {
		next, err := job.Next(now)
		if err != nil {
			return job, err
		}
		if next.IsZero() {
			return job, invalid("provide runAt, intervalSeconds or localTime and timeZone")
		}
		job.NextRunAt = next.Format(time.RFC3339Nano)
	}
	if spec.LocalTime != "" {
		if _, err := job.Next(now); err != nil {
			return job, err
		}
	}
	if err = saveAppJob(tx, job); err != nil {
		return job, err
	}
	return job, tx.Commit()
}

func (st *Store) AllAppSchedules() ([]AppSchedule, error) {
	rows, err := st.db.Query("SELECT data FROM app_jobs ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AppSchedule{}
	for rows.Next() {
		var raw []byte
		var job AppSchedule
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(raw, &job); err != nil {
			return nil, err
		}
		out = append(out, job)
	}
	return out, rows.Err()
}

func (st *Store) ClaimAppSchedule(id, occurrence string) (AppSchedule, error) {
	tx, err := st.db.Begin()
	if err != nil {
		return AppSchedule{}, err
	}
	defer tx.Rollback()
	job, err := readAppJob(tx, id)
	if err != nil {
		return job, err
	}
	if !job.Active || job.State == "running" || job.NextRunAt != occurrence {
		return job, ErrConflict
	}
	job.State = "running"
	job.Occurrence = occurrence
	job.LeaseUntil = time.Now().UTC().Add(2 * time.Minute).Format(time.RFC3339Nano)
	job.Revision++
	if err = saveAppJob(tx, job); err != nil {
		return job, err
	}
	return job, tx.Commit()
}

func (st *Store) FinishAppSchedule(id, occurrence string, runErr error, recovering bool) error {
	tx, err := st.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	job, err := readAppJob(tx, id)
	if err != nil {
		return err
	}
	if job.State != "running" || job.Occurrence != occurrence {
		return ErrConflict
	}
	if recovering {
		if expiry, err := time.Parse(time.RFC3339Nano, job.LeaseUntil); err == nil && expiry.After(time.Now()) {
			return ErrConflict
		}
	}
	now := time.Now().UTC()
	job.LastRunAt = now.Format(time.RFC3339Nano)
	job.State = "completed"
	job.LastError = ""
	job.Revision++
	job.LeaseUntil = ""
	if runErr != nil {
		job.State = "failed"
		job.LastError = runErr.Error()
	}
	app, appErr := readApp(tx, job.AppID)
	if appErr != nil && !errors.Is(appErr, ErrNotFound) {
		return appErr
	}
	projectExists := true
	if appErr == nil {
		project, _, err := record(tx, "projects", app.ProjectID)
		if err != nil {
			return err
		}
		projectExists = project != nil
	}
	if appErr != nil || app.Archived || !projectExists {
		job.Active = false
		job.State = "cancelled"
		job.NextRunAt = ""
	} else if recovering && (job.Command == "" || job.CommandDone) {
		job.State = "scheduled"
		job.RetryAt = ""
	} else if runErr != nil && (job.Command == "" || job.CommandDone) && job.Attempts < 8 {
		job.Attempts++
		job.State = "retrying"
		job.RetryAt = now.Add(min(time.Duration(1<<min(job.Attempts-1, 4)), 15) * time.Minute).Format(time.RFC3339Nano)
	} else {
		if recovering {
			job.State = "interrupted"
		}
		next, nextErr := job.Next(now)
		if nextErr != nil {
			return nextErr
		}
		job.Active = job.Active && !next.IsZero()
		job.NextRunAt = ""
		job.RetryAt = ""
		job.Attempts = 0
		job.CommandDone = false
		if !next.IsZero() {
			job.NextRunAt = next.Format(time.RFC3339Nano)
		}
	}
	if err = saveAppJob(tx, job); err != nil {
		return err
	}
	return tx.Commit()
}

func (st *Store) AppScheduleCommandDone(id, occurrence string) error {
	tx, err := st.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	job, err := readAppJob(tx, id)
	if err != nil {
		return err
	}
	if job.State != "running" || job.Occurrence != occurrence {
		return ErrConflict
	}
	job.CommandDone = true
	if err = saveAppJob(tx, job); err != nil {
		return err
	}
	return tx.Commit()
}

func (st *Store) DeleteAppSchedule(appID, id string) error {
	tx, err := st.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	job, err := readAppJob(tx, id)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if job.AppID != appID {
		return ErrNotFound
	}
	if job.State == "running" {
		return invalid("this schedule is running; delete it after it finishes")
	}
	if _, err = tx.Exec("DELETE FROM app_jobs WHERE id=? AND app_id=?", id, appID); err != nil {
		return err
	}
	return tx.Commit()
}

// Archiving stops future runs atomically with revoking the app credential. A
// command already in progress finishes through the normal worker lifecycle.
func pauseAppSchedules(tx *sql.Tx, appID string) error {
	rows, err := tx.Query("SELECT data FROM app_jobs WHERE app_id=?", appID)
	if err != nil {
		return err
	}
	var jobs []AppSchedule
	for rows.Next() {
		var raw []byte
		var job AppSchedule
		if err = rows.Scan(&raw); err != nil {
			rows.Close()
			return err
		}
		if err = json.Unmarshal(raw, &job); err != nil {
			rows.Close()
			return err
		}
		jobs = append(jobs, job)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, job := range jobs {
		job.Active = false
		job.Revision++
		if job.State != "running" {
			job.State = "paused"
		}
		if err = saveAppJob(tx, job); err != nil {
			return err
		}
	}
	return nil
}

func ScheduleEventID(job AppSchedule) string {
	sum := sha256.Sum256([]byte(job.ID + "\x00" + job.Occurrence))
	return fmt.Sprintf("schedule-%x", sum[:16])
}
