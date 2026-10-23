CREATE TABLE "account_deletion" (
	"id" text PRIMARY KEY NOT NULL,
	"owner_id" text,
	"receipt_hash" text NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"requested_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL,
	"lease_token" text,
	"lease_until" bigint DEFAULT 0 NOT NULL,
	"error_code" text,
	CONSTRAINT "account_deletion_owner_id_unique" UNIQUE("owner_id"),
	CONSTRAINT "account_deletion_receipt_hash_unique" UNIQUE("receipt_hash")
);
--> statement-breakpoint
CREATE INDEX "account_deletion_due" ON "account_deletion" USING btree ("status","updated_at");