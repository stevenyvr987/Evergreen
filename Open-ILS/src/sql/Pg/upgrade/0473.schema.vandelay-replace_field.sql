
BEGIN;

INSERT INTO config.upgrade_log (version) VALUES ('0473'); -- miker

CREATE OR REPLACE FUNCTION vandelay.replace_field ( target_xml TEXT, source_xml TEXT, field TEXT ) RETURNS TEXT AS $_$
DECLARE
    xml_output TEXT;
    parsed_target TEXT;
    curr_field TEXT;
BEGIN

    parsed_target := vandelay.strip_field( target_xml, ''); -- this dance normalizes the format of the xml for the IF below

    FOR curr_field IN SELECT UNNEST( STRING_TO_ARRAY(field, ',') ) LOOP -- naive split, but it's the same we use in the perl

        xml_output := vandelay.strip_field( parsed_target, curr_field);

        IF xml_output <> parsed_target  AND curr_field ~ E'~' THEN
            -- we removed something, and there was a regexp restriction in the curr_field definition, so proceed
            xml_output := vandelay.add_field( xml_output, source_xml, curr_field, 1 );
        ELSIF curr_field !~ E'~' THEN
            -- No regexp restriction, add the curr_field
            xml_output := vandelay.add_field( xml_output, source_xml, curr_field, 0 );
        END IF;

        parsed_target := xml_output; -- in prep for any following loop iterations

    END LOOP;

    RETURN xml_output;
END;
$_$ LANGUAGE PLPGSQL;

COMMIT;
