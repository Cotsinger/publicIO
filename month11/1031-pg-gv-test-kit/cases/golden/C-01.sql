SET search_path TO unics_cordis, public;

SELECT DISTINCT i.institutions_name
FROM institutions i
JOIN project_members pm ON pm.institution_id = i.unics_id
JOIN projects p ON p.unics_id = pm.project
JOIN project_erc_panels pep ON pep.project = p.unics_id
JOIN erc_panels ep ON ep.code = pep.panel
JOIN countries c ON c.unics_id = i.country_id
WHERE ep.code LIKE 'LS%' AND c.country_name = 'Spain'
ORDER BY 1;
