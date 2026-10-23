CREATE TABLE `account_deletion` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text,
	`receipt_hash` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`requested_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`lease_token` text,
	`lease_until` integer DEFAULT 0 NOT NULL,
	`error_code` text
);
--> statement-breakpoint
CREATE UNIQUE INDEX `account_deletion_owner_id_unique` ON `account_deletion` (`owner_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `account_deletion_receipt_hash_unique` ON `account_deletion` (`receipt_hash`);--> statement-breakpoint
CREATE INDEX `account_deletion_due` ON `account_deletion` (`status`,`updated_at`);