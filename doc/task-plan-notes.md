
# Grammary Thing

    task  := title (flags)* ( break switches )* ( break description )

    ; Probably we can skip switches for the time being.  Who even uses them??

    break := "---" | "\n"
    task  := title (flags*) ( break switches )*
    flags := "(" "!"+ ")"

    user-or-team := username | teamname
    user-at-team := username "@" teamname

    command :=  "++" task
             |  ">>" user-or-team task
             |  ">>" user-at-team task
             |  ">>" team task

# What's the plan?

  title       - required!
  description - optional (default to empty string?)
  teamId      - required but we have a default
  assigneeId  - optional
  priority    - optional
  labelIds    - optional - right now, only happen when "user" is triage
  stateId     - optional

