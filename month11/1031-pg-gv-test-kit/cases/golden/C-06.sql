SET search_path TO unics_cordis, public;

SELECT c.country_name, COUNT(DISTINCT i.unics_id) AS institution_count
FROM institutions i
JOIN countries c ON c.unics_id = i.country_id
GROUP BY c.country_name
ORDER BY institution_count DESC
LIMIT 5;
