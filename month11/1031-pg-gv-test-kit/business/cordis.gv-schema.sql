--
-- PostgreSQL database dump
--


-- Dumped from database version 18.6 (Debian 18.6-1.pgdg13+2)
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg13+2)

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET client_min_messages = warning;

--
-- Name: unics_cordis; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA unics_cordis;




--
-- Name: activity_types; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.activity_types (
    code text NOT NULL,
    description text
);


--
-- Name: countries; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.countries (
    unics_id integer NOT NULL,
    country_name text NOT NULL,
    country_code2 character varying(2) NOT NULL,
    country_code3 character varying(3) NOT NULL,
    geocode_country_code character varying(2)
);


--
-- Name: ec_framework_programs; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.ec_framework_programs (
    ec_framework_program_name text NOT NULL
);


--
-- Name: projects; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.projects (
    unics_id integer NOT NULL,
    acronym text,
    title text,
    ec_call text,
    ec_fund_scheme text,
    cordis_ref text,
    ec_ref text,
    start_date date,
    end_date date,
    start_year integer,
    end_year integer,
    homepage text,
    total_cost double precision,
    ec_max_contribution double precision,
    framework_program text,
    objective text,
    principal_investigator integer
);


--
-- Name: erc_panels; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.erc_panels (
    code text NOT NULL,
    description text,
    part_of text
);


--
-- Name: erc_research_domains; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.erc_research_domains (
    code text NOT NULL,
    description text
);


--
-- Name: eu_territorial_units; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.eu_territorial_units (
    geocode_regions text NOT NULL,
    description text,
    geocode_level integer,
    nuts_version text
);


--
-- Name: funding_schemes; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.funding_schemes (
    code text NOT NULL,
    title text
);


--
-- Name: institutions; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.institutions (
    unics_id integer NOT NULL,
    country_id integer,
    institutions_name text NOT NULL,
    geocode_regions_3 text,
    db_pedia_url text,
    wikidata_url text,
    grid_id text,
    acronym text,
    short_name text,
    website text,
    document_vectors tsvector
);


--
-- Name: people; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.people (
    unics_id integer NOT NULL,
    full_name text
);


--
-- Name: people_unics_id_seq; Type: SEQUENCE; Schema: unics_cordis; Owner: -
--

CREATE SEQUENCE unics_cordis.people_unics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: people_unics_id_seq; Type: SEQUENCE OWNED BY; Schema: unics_cordis; Owner: -
--

ALTER SEQUENCE unics_cordis.people_unics_id_seq OWNED BY unics_cordis.people.unics_id;


--
-- Name: programmes; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.programmes (
    code text NOT NULL,
    rcn text,
    title text,
    short_name text,
    parent text
);


--
-- Name: project_erc_panels; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.project_erc_panels (
    project integer NOT NULL,
    panel text NOT NULL
);


--
-- Name: project_member_roles; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.project_member_roles (
    code text NOT NULL,
    description text
);


--
-- Name: project_members; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.project_members (
    unics_id integer NOT NULL,
    project integer NOT NULL,
    pic_number text,
    rcn text,
    member_name text,
    activity_type text,
    country text,
    street text,
    city text,
    postal_code text,
    ec_contribution double precision,
    institution_id integer,
    member_role text NOT NULL,
    geocode_regions_3 text,
    member_short_name text,
    department_name text,
    vat_number character varying,
    latitude numeric,
    longitude numeric,
    region_code text,
    region_name text
);


--
-- Name: project_members_unics_id_seq; Type: SEQUENCE; Schema: unics_cordis; Owner: -
--

CREATE SEQUENCE unics_cordis.project_members_unics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_members_unics_id_seq; Type: SEQUENCE OWNED BY; Schema: unics_cordis; Owner: -
--

ALTER SEQUENCE unics_cordis.project_members_unics_id_seq OWNED BY unics_cordis.project_members.unics_id;


--
-- Name: project_programmes; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.project_programmes (
    project integer NOT NULL,
    programme text NOT NULL
);


--
-- Name: project_subject_areas; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.project_subject_areas (
    project integer NOT NULL,
    subject_area text NOT NULL
);


--
-- Name: project_topics; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.project_topics (
    project integer NOT NULL,
    topic text NOT NULL
);


--
-- Name: projects_unics_id_seq; Type: SEQUENCE; Schema: unics_cordis; Owner: -
--

CREATE SEQUENCE unics_cordis.projects_unics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: projects_unics_id_seq; Type: SEQUENCE OWNED BY; Schema: unics_cordis; Owner: -
--

ALTER SEQUENCE unics_cordis.projects_unics_id_seq OWNED BY unics_cordis.projects.unics_id;


--
-- Name: subject_areas; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.subject_areas (
    code text NOT NULL,
    title text,
    description text
);


--
-- Name: topics; Type: TABLE; Schema: unics_cordis; Owner: -
--

CREATE TABLE unics_cordis.topics (
    code text NOT NULL,
    rcn text,
    title text
);


--
-- Name: people unics_id; Type: DEFAULT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.people ALTER COLUMN unics_id SET DEFAULT nextval('unics_cordis.people_unics_id_seq'::regclass);


--
-- Name: project_members unics_id; Type: DEFAULT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.project_members ALTER COLUMN unics_id SET DEFAULT nextval('unics_cordis.project_members_unics_id_seq'::regclass);


--
-- Name: projects unics_id; Type: DEFAULT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.projects ALTER COLUMN unics_id SET DEFAULT nextval('unics_cordis.projects_unics_id_seq'::regclass);


--
-- Name: activity_types activity_types_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.activity_types
    ADD CONSTRAINT activity_types_pkey PRIMARY KEY (code);


--
-- Name: countries countries_country_code2_key; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.countries
    ADD CONSTRAINT countries_country_code2_key UNIQUE (country_code2);


--
-- Name: countries countries_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.countries
    ADD CONSTRAINT countries_pkey PRIMARY KEY (unics_id);


--
-- Name: ec_framework_programs ec_framework_programs_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.ec_framework_programs
    ADD CONSTRAINT ec_framework_programs_pkey PRIMARY KEY (ec_framework_program_name);


--
-- Name: erc_panels erc_panels_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.erc_panels
    ADD CONSTRAINT erc_panels_pkey PRIMARY KEY (code);


--
-- Name: erc_research_domains erc_research_domains_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.erc_research_domains
    ADD CONSTRAINT erc_research_domains_pkey PRIMARY KEY (code);


--
-- Name: eu_territorial_units eu_territorial_units_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.eu_territorial_units
    ADD CONSTRAINT eu_territorial_units_pkey PRIMARY KEY (geocode_regions);


--
-- Name: funding_schemes funding_schemes_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.funding_schemes
    ADD CONSTRAINT funding_schemes_pkey PRIMARY KEY (code);


--
-- Name: institutions institutions_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.institutions
    ADD CONSTRAINT institutions_pkey PRIMARY KEY (unics_id);


--
-- Name: people people_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.people
    ADD CONSTRAINT people_pkey PRIMARY KEY (unics_id);


--
-- Name: programmes programmes_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.programmes
    ADD CONSTRAINT programmes_pkey PRIMARY KEY (code);


--
-- Name: project_erc_panels project_erc_panels_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.project_erc_panels
    ADD CONSTRAINT project_erc_panels_pkey PRIMARY KEY (project);


--
-- Name: project_member_roles project_member_roles_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.project_member_roles
    ADD CONSTRAINT project_member_roles_pkey PRIMARY KEY (code);


--
-- Name: project_members project_members_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.project_members
    ADD CONSTRAINT project_members_pkey PRIMARY KEY (unics_id);


--
-- Name: project_programmes project_programmes_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.project_programmes
    ADD CONSTRAINT project_programmes_pkey PRIMARY KEY (project, programme);


--
-- Name: project_subject_areas project_subject_areas_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.project_subject_areas
    ADD CONSTRAINT project_subject_areas_pkey PRIMARY KEY (project, subject_area);


--
-- Name: project_topics project_topics_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.project_topics
    ADD CONSTRAINT project_topics_pkey PRIMARY KEY (project, topic);


--
-- Name: projects projects_cordis_ref_key; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.projects
    ADD CONSTRAINT projects_cordis_ref_key UNIQUE (cordis_ref);


--
-- Name: projects projects_ec_ref_key; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.projects
    ADD CONSTRAINT projects_ec_ref_key UNIQUE (ec_ref);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (unics_id);


--
-- Name: subject_areas subject_areas_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.subject_areas
    ADD CONSTRAINT subject_areas_pkey PRIMARY KEY (code);


--
-- Name: topics topics_pkey; Type: CONSTRAINT; Schema: unics_cordis; Owner: -
--

ALTER TABLE ONLY unics_cordis.topics
    ADD CONSTRAINT topics_pkey PRIMARY KEY (code);


--
-- Name: project_members_institution_id_idx; Type: INDEX; Schema: unics_cordis; Owner: -
--

CREATE INDEX project_members_institution_id_idx ON unics_cordis.project_members USING btree (institution_id);


--
-- Name: erc_panels erc_panels_part_of_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: institutions institutions_countries_unics_id_fk; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: institutions institutions_geocode_regions_3_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: programmes programmes_parent_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_erc_panels project_erc_panels_panel_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_erc_panels project_erc_panels_project_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_members project_members_activity_type_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_members project_members_institutions_unics_id_fk; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_members project_members_member_role_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_members project_members_nuts3_code_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_members project_members_project_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_programmes project_programmes_programme_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_programmes project_programmes_project_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_subject_areas project_subject_areas_project_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_subject_areas project_subject_areas_subject_area_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_topics project_topics_project_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: project_topics project_topics_topic_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: projects projects_ec_fund_scheme_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: projects projects_framework_program_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- Name: projects projects_principal_investigator_fkey; Type: FK CONSTRAINT; Schema: unics_cordis; Owner: -
--



--
-- PostgreSQL database dump complete
--


