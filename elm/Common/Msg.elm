module Common.Msg exposing (..)

import Common.Types exposing (..)
import Eth.Sentry.Tx as TxSentry
import Eth.Types exposing (Address, TxHash)
import Routing exposing (Route)
import TokenValue exposing (TokenValue)
import UserNotice as UN
import Wallet exposing (Wallet)


type MsgUp
    = GotoRoute Route
    | ConnectToWeb3
    | ShowOrHideAddress PhaceIconId
    | AddUserNotice UN.UserNotice
    | GTag GTagData
    | NonRepeatingGTag GTagData
    | NoOp


type MsgDown
    = UpdateWallet Wallet


gTag : String -> String -> String -> Int -> MsgUp
gTag event category label value =
    GTag <|
        GTagData
            event
            category
            label
            value
