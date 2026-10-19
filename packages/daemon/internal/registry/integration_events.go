package registry

import (
	"encoding/json"
	"time"
)

// IntegrationEvents keeps completed delivery history off the dispatch path. These
// private records never enter workspace snapshots, exports, or project copies.
func (st *Store) IntegrationEvents(connectionID string, pending bool) ([]json.RawMessage, error) {
	query := "SELECT data FROM surface_records WHERE kind='integration-event'"
	args := []any{}
	if connectionID != "" {
		query += " AND json_extract(data,'$.integrationId')=?"
		args = append(args, connectionID)
	}
	if pending {
		query += " AND json_extract(data,'$.state') IN ('queued','running') ORDER BY updated_at LIMIT 256"
	} else {
		query += " ORDER BY updated_at DESC LIMIT 100"
	}
	rows, err := st.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []json.RawMessage{}
	for rows.Next() {
		var data json.RawMessage
		if err := rows.Scan(&data); err != nil {
			return nil, err
		}
		out = append(out, data)
	}
	return out, rows.Err()
}

func (st *Store) PruneIntegrationEvents() error {
	_, err := st.db.Exec("DELETE FROM surface_records WHERE kind='integration-event' AND updated_at < ? AND json_extract(data,'$.state') IN ('delivered','failed')", time.Now().Add(-30*24*time.Hour).UTC().Format(time.RFC3339Nano))
	return err
}
