create or replace function meeting.patients_last_appointments(pat_id integer)
  returns table
          (
            appointment_id integer,
            doctor_id integer,
            patient_id integer,
            appointment_datetime timestamp,
            appointment_location varchar(255)
          )
  immutable
  language plpgsql
as
$$
begin
  return query
    with ranked_appointments as (
      select a.id
           , a.doctor_id
           , a.patient_id
           , a.datetime
           , a.location
           , rank() over (order by a.datetime::date desc) as rank
      from meeting.appointments as a
      where a.patient_id = pat_id
    )
    select ra.id, ra.doctor_id, ra.patient_id, ra.datetime, ra.location
    from ranked_appointments as ra
    where ra.rank = 1;
end;
$$;


create or replace function meeting.patients_last_appointments_for_query_1(pat_id integer, first_name_pat text,
  last_name_pat text)
  returns table
          (
            appointment_id int
          , doctor_id int
          , patient_id int
          , appointment_datetime timestamp
          , appointment_location varchar
          , first_name varchar
          , last_name varchar
          , is_dead bool
          , email varchar
          , clinic_number varchar
          )
  immutable
  language plpgsql
as
$$
begin
  return query
    select a.appointment_id, a.doctor_id, a.patient_id, a.appointment_datetime, a.appointment_location,
           u.first_name, u.last_name, u.is_dead, u.email, d.clinic_number
    from meeting.patients_last_appointments(pat_id) as a
    join usr.users as u
      on u.id = a.doctor_id
    join usr.doctors as d
      on d.id = a.doctor_id
    where tools.xor(
       u.first_name similar to first_name_pat,
       u.last_name  similar to last_name_pat
    );
end;
$$;

create or replace function meeting.doctors_appointments_report(begin_date date, end_date date)
  returns table
          (
            doctor_id                            int
          , day_of_week                          text
          , time_slot                            time
          , total_num_appointments_per_time_slot bigint
          , average_visits_per_time_slot         numeric
          )
  immutable
  language plpgsql
as
$$
declare
  num_same_time_slots int := (end_date - begin_date) / 7;
begin
  return query
    with dated_appointments as
    (
      select a.doctor_id
           , to_char(a.datetime, 'day') as day_of_week
           , date_trunc('hour', a.datetime)::time as time_slot
           , a.patient_id
      from meeting.appointments as a
    ),
    calculated_appointments as
    (
      select distinct
             a.doctor_id
           , a.day_of_week
           , a.time_slot
           , count(a.patient_id) over(partition by a.doctor_id
                                                 , a.day_of_week
                                                 , a.time_slot) as total_num_appointments_per_time_slot
      from dated_appointments as a
    )
    select a.doctor_id
         , a.day_of_week
         , a.time_slot
         , a.total_num_appointments_per_time_slot
         , (a.total_num_appointments_per_time_slot::numeric / num_same_time_slots) as average_visits_per_time_slot
    from calculated_appointments as a;
end;
$$;


create or replace function finance.get_possible_profit_last_month()
  returns money
  language sql
as
$$
with
  appointment_counts as
    (
      select
        patient_id
      , count(id) as appointments_count
      from
        meeting.appointments
      where
        datetime between date_trunc('month', current_date - interval '1 month') and date_trunc('month', current_date)
      group by
        patient_id
    ),
  collapsed_data as
    (
      select
        a.patient_id
      , a.appointments_count
      , tools.get_age(u.birth_date) as age
      from
        appointment_counts as a
          join usr.users as u on a.patient_id = u.id
    )
select coalesce(sum(tools.charge(age, appointments_count)), 0::money) as possible_profit
from
  collapsed_data;
$$;


create or replace function usr.get_experiences_doctors(
patients_per_year int, -- 5
patients_total int, -- 100
years_period int -- 10
)
  returns table
          (
            doctor_id          int,
            total_appointments numeric,
            first_name         varchar(255),
            last_name          varchar(255),
            email              varchar(255),
            birth_date         date,
            is_dead            bool
          )
  language sql
as
$$
with
  yearly_data as
    (
      select
        doctor_id
      , count(*)                    as appointments_count
      , date_part('year', datetime) as year
      from
        meeting.appointments
      where -- work only with data for last 10 years
            date_part('year', datetime) between date_part('year', now() - make_interval(years := years_period))
              and date_part('year', now())
      group by
        doctor_id, date_part('year', datetime)
      having -- Ensures that doctor had an appointment with at least 5 patients during the period
             count(distinct patient_id) >= patients_per_year
    )
, passed_constraints as
    (select
       doctor_id
     , sum(appointments_count) as total_appointments
     from
       yearly_data as y
         join usr.users as u on y.doctor_id = u.id
     group by
       doctor_id
     having
         sum(appointments_count) >= patients_total -- Doctor have in total at least 100 appointments
     and count(year) = years_period -- Doctor had an appointment with at least 5 patients each year during 10 years
    )
select
  p.doctor_id
, p.total_appointments
, u.first_name
, u.last_name
, u.email
, u.birth_date
, u.is_dead
from
  passed_constraints as p
    join usr.users as u on p.doctor_id = u.id;
$$;

create or replace function usr.frequent_patients(start_date date, end_date date)
  returns table
          (
            patient_id              int,
            total_appointment_count numeric,
            first_name              varchar(255),
            last_name               varchar(255),
            email                   varchar(255),
            birth_date              date,
            is_dead                 bool,
            insurance_company       varchar(255),
            insurance_number        varchar(255)
          )
  language sql
as
$$
with
  week_data as
    (select
       patient_id
--   get how many appointments there been during each week from the start date
     , tools.number_of_weeks_between(start_date, datetime::date) as week_no
     , count(*)                                                  as appointment_count
     from
       meeting.appointments
     where
       datetime between start_date and end_date
     group by
       patient_id, tools.number_of_weeks_between(start_date,
                                                 datetime::date)
     having
       count(*) >= 2
--    consider only those who had at least 2 appointments per week

    )
, result_patients as
    (
      select
        patient_id
      , sum(appointment_count) as total_appointment_count
      from
        week_data
      group by
        patient_id
      having
        -- 1 + since function may returns values from 0 to (start+end) div 7
        count(*) = 1 + tools.number_of_weeks_between(start_date, end_date)
    )
select
  r.patient_id
, r.total_appointment_count
, u.first_name
, u.last_name
, u.email
, u.birth_date
, u.is_dead
, u.insurance_company
, u.insurance_number
from
  result_patients as r
    join usr.users as u on r.patient_id = u.id
$$;
