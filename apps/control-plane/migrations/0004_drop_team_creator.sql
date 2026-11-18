-- Deleting an account keeps the teams other people are still on, so a team no longer points at
-- the person who created it. Nothing read the column.
ALTER TABLE teams DROP COLUMN created_by;
