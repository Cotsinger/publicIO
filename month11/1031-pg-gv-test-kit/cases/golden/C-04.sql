SET search_path TO unics_cordis, public;

SELECT p.acronym
FROM projects p
JOIN project_topics pt1 ON pt1.project = p.unics_id AND lower(pt1.topic) = 'fetopen-1-2014'
JOIN project_topics pt2 ON pt2.project = p.unics_id AND lower(pt2.topic) = 'fetopen-ria-2014-2015'
ORDER BY 1;
