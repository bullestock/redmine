delete from projects where identifier != 'gh-pais';

delete from issues where project_id not in (select id from projects);
delete from custom_fields_projects where project_id not in (select id from projects);
delete from issue_categories where project_id not in (select id from projects);
delete from queries where project_id not in (select id from projects);
delete from repositories where project_id not in (select id from projects);
delete from time_entries where project_id not in (select id from projects);
delete from versions where project_id not in (select id from projects);
delete from wiki_pages where wiki_id not in (select id from projects);
delete from wiki_redirects where wiki_id not in (select id from projects);
delete from wikis where project_id not in (select id from projects);
