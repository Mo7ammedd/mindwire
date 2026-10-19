package registry

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"time"
)

func appTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// AddAppToken prepares a replacement grant without revoking a working grant.
// The service retires old grants only after the protected file is published.
func (st *Store) AddAppToken(id, token string) error {
	tx, err := st.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	app, err := readApp(tx, id)
	if err != nil {
		return err
	}
	if app.Archived {
		return ErrDeleted
	}
	if _, err = tx.Exec("INSERT OR IGNORE INTO app_token_grants VALUES (?,?)", id, appTokenHash(token)); err != nil {
		return err
	}
	return tx.Commit()
}

func (st *Store) CheckAppToken(id, token string) bool {
	if token == "" {
		return false
	}
	candidate := appTokenHash(token)
	var hash string
	err := st.db.QueryRow("SELECT hash FROM app_token_grants WHERE app_id=? AND hash=?", id, candidate).Scan(&hash)
	return err == nil && subtle.ConstantTimeCompare([]byte(hash), []byte(candidate)) == 1
}

func (st *Store) RetainAppToken(id, token string) error {
	tx, err := st.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	app, err := readApp(tx, id)
	if err != nil {
		return err
	}
	if app.Archived {
		return ErrDeleted
	}
	var exists int
	hash := appTokenHash(token)
	if err = tx.QueryRow("SELECT count(*) FROM app_token_grants WHERE app_id=? AND hash=?", id, hash).Scan(&exists); err != nil {
		return err
	}
	if exists != 1 {
		return ErrConflict
	}
	if _, err = tx.Exec("DELETE FROM app_token_grants WHERE app_id=? AND hash<>?", id, hash); err != nil {
		return err
	}
	return tx.Commit()
}

func (st *Store) DiscardAppToken(id, token string) error {
	_, err := st.db.Exec("DELETE FROM app_token_grants WHERE app_id=? AND hash=?", id, appTokenHash(token))
	return err
}

func (st *Store) RevokeAppToken(id string) error {
	_, err := st.db.Exec("DELETE FROM app_token_grants WHERE app_id=?", id)
	return err
}

func (st *Store) ClaimAppNotification(appID, eventID string) (bool, error) {
	now := time.Now().UTC()
	cutoff := now.Add(-5 * time.Minute).Format(time.RFC3339Nano)
	result, err := st.db.Exec("INSERT INTO app_notifications VALUES (?,?,'sending',?) ON CONFLICT(app_id,event_id) DO UPDATE SET status='sending',updated_at=excluded.updated_at WHERE app_notifications.status='failed' OR (app_notifications.status='sending' AND app_notifications.updated_at<?)", appID, eventID, now.Format(time.RFC3339Nano), cutoff)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	if err == nil && n == 0 {
		var state string
		if err = st.db.QueryRow("SELECT status FROM app_notifications WHERE app_id=? AND event_id=?", appID, eventID).Scan(&state); err != nil {
			return false, err
		}
		if state == "sending" {
			return false, ErrConflict
		}
	}
	return n > 0, err
}
func (st *Store) FinishAppNotification(appID, eventID string, deliveryErr error) error {
	state := "delivered"
	if deliveryErr != nil {
		state = "failed"
	}
	_, err := st.db.Exec("UPDATE app_notifications SET status=?,updated_at=? WHERE app_id=? AND event_id=?", state, time.Now().UTC().Format(time.RFC3339Nano), appID, eventID)
	if err == nil {
		_, err = st.db.Exec("DELETE FROM app_notifications WHERE rowid IN (SELECT rowid FROM app_notifications WHERE app_id=? AND status<>'sending' ORDER BY updated_at DESC LIMIT -1 OFFSET 1000)", appID)
	}
	return err
}
