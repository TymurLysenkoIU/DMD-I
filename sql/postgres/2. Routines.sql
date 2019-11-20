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
            doctor_id int
          , visits_total_number int
          , avg_visits_per_week numeric
          )
  immutable
  language plpgsql
as
$$
declare
  num_weeks_between_dates int := tools.number_of_weeks_between(begin_date, end_date);
begin
  num_weeks_between_dates :=
    case num_weeks_between_dates
      when 0 then 1
      else num_weeks_between_dates
    end;

  return query
    with doctors_weeks as
    (
      select a.doctor_id
           , tools.number_of_weeks_between(begin_date, datetime::date) as week_no
      from meeting.appointments as a
      where a.datetime::date between begin_date and end_date
    ),
    doctors_visits as
    (
      select distinct dw.doctor_id
           , dw.week_no
           , count(*) over(partition by dw.doctor_id) as visits_total_number
           , count(*) over(partition by dw.doctor_id, dw.week_no) as visits_per_week
      from doctors_weeks as dw
    )
    select dv.doctor_id
         , dv.visits_total_number::int
         , sum(dv.visits_per_week)
           /
           num_weeks_between_dates as avg_visits_per_week
    from doctors_visits as dv
    group by dv.doctor_id, dv.visits_total_number;
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
select sum(tools.charge(age, appointments_count))
from
  collapsed_data;
$$;

create or replace function usr.get_experiences_doctors()
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
      , count(id)                   as appointments_count
      , date_part('year', datetime) as year
      from
        meeting.appointments
      where -- work only with data for last 10 years
            date_part('year', datetime) between date_part('year', now() - interval '10 years')
              and date_part('year', now())
      group by
        doctor_id, date_part('year', datetime)
      having -- Ensures that doctor had an appointment with at least 5 patients during the period
             count(id) >= 5
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
         sum(appointments_count) >= 100 -- Doctor have in total at least 100 appointments
     and count(year) = 10 -- Doctor had an appointment with at least 5 patients each year during 10 years
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
