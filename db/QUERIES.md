# Populate a new tournament and match in the database

```sql
-- 1. Insert Tournament (using ON CONFLICT so it doesn't error if it's already there)
INSERT INTO tournaments (name, year) 
VALUES ('europe smash', 2026)
ON CONFLICT (name, year) DO NOTHING;

-- 2. Insert Players
INSERT INTO players (name) VALUES 
('Moregard'), ('Ionescu'), ('Fan'), ('Xu'), ('Jorgic')
ON CONFLICT (name) DO NOTHING;

-- 3. Match 1 (Singles)
WITH m1 AS (
    INSERT INTO matches (tournament_id, match_timestamp, is_doubles)
    SELECT 
        id, 
        '2026-01-01 00:00:00+00'::timestamptz + (600 || ' seconds')::interval, 
        FALSE 
    FROM tournaments WHERE name = 'europe smash' AND year = 2026
    RETURNING id
)
INSERT INTO match_participants (match_id, player_id, side)
VALUES 
    ((SELECT id FROM m1), (SELECT id FROM players WHERE name = 'Moregard'), 'A'),
    ((SELECT id FROM m1), (SELECT id FROM players WHERE name = 'Ionescu'), 'B');

-- 4. Match 2 (Doubles)
WITH m2 AS (
    INSERT INTO matches (tournament_id, match_timestamp, is_doubles)
    SELECT 
        id, 
        '2026-01-01 00:00:00+00'::timestamptz + (1000 || ' seconds')::interval, 
        TRUE 
    FROM tournaments WHERE name = 'europe smash' AND year = 2026
    RETURNING id
)
INSERT INTO match_participants (match_id, player_id, side)
VALUES 
    ((SELECT id FROM m2), (SELECT id FROM players WHERE name = 'Fan'), 'A'),
    ((SELECT id FROM m2), (SELECT id FROM players WHERE name = 'Xu'), 'A'),
    ((SELECT id FROM m2), (SELECT id FROM players WHERE name = 'Jorgic'), 'B'),
    ((SELECT id FROM m2), (SELECT id FROM players WHERE name = 'Moregard'), 'B');
```

# Read tournaments and matches from the database
SELECT 
    t.name AS tournament,
    t.year,
    -- Formats the timestamp into a readable date/time
    TO_CHAR(m.match_timestamp, 'Mon DD, YYYY HH24:MI') AS match_time,
    -- Groups Team A players with a slash
    STRING_AGG(p.name, ' / ') FILTER (WHERE mp.side = 'A') AS team_a,
    -- Groups Team B players with a slash
    STRING_AGG(p.name, ' / ') FILTER (WHERE mp.side = 'B') AS team_b,
    m.is_doubles
FROM matches m
JOIN tournaments t ON m.tournament_id = t.id
JOIN match_participants mp ON m.id = mp.match_id
JOIN players p ON mp.player_id = p.id
GROUP BY t.name, t.year, m.id, m.match_timestamp, m.is_doubles
ORDER BY m.match_timestamp ASC;

# Reset data in the table
It resets data in multiple tables because they are using foreign keys:

```
TRUNCATE TABLE matches, match_participants RESTART IDENTITY;
```

# print all tables query

```
SELECT 
    table_name, 
    column_name, 
    data_type, 
    is_nullable,
    column_default
FROM 
    information_schema.columns
WHERE 
    table_schema = 'public'
ORDER BY 
    table_name, 
    ordinal_position;
```