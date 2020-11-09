module Farm.State exposing (..)

import ChainCmd exposing (ChainCmd)
import Common.Msg exposing (MsgDown, MsgUp)
import Common.Types exposing (..)
import Contracts.Staking as StakingContract
import Eth.Types exposing (Address)
import Farm.Types exposing (..)
import Time
import TokenValue exposing (TokenValue)
import UserNotice as UN
import Wallet exposing (Wallet)


init : Wallet -> Time.Posix -> ( Model, Cmd Msg )
init wallet now =
    ( { wallet = wallet
      , userStakingInfo = Nothing
      , depositWithdrawUXModel = Nothing
      , now = now
      }
    , case Wallet.userInfo wallet of
        Just userInfo ->
            fetchUserStakingInfoCmd userInfo.address

        Nothing ->
            Cmd.none
    )


update : Msg -> Model -> UpdateResult
update msg prevModel =
    case msg of
        NoOp ->
            justModelUpdate prevModel

        MsgUp msgUp ->
            UpdateResult
                prevModel
                Cmd.none
                ChainCmd.none
                [ msgUp ]

        UpdateNow newNow ->
            justModelUpdate
                { prevModel | now = newNow }

        AmountInputChanged newInput ->
            case prevModel.depositWithdrawUXModel of
                Just ( depositOrWithdraw, amountInputUXModel ) ->
                    justModelUpdate
                        { prevModel
                            | depositWithdrawUXModel =
                                Just
                                    ( depositOrWithdraw
                                    , { amountInputUXModel
                                        | amountInput = newInput
                                      }
                                    )
                        }

                Nothing ->
                    justModelUpdate prevModel

        UXBack ->
            justModelUpdate
                { prevModel
                    | depositWithdrawUXModel = Nothing
                }

        DoUnlock ->
            UpdateResult
                prevModel
                Cmd.none
                doApproveChainCmd
                []

        StartDeposit defaultValue ->
            justModelUpdate
                { prevModel
                    | depositWithdrawUXModel = Just ( Deposit, { amountInput = TokenValue.toFloatString Nothing defaultValue } )
                }

        StartWithdraw defaultValue ->
            justModelUpdate
                { prevModel
                    | depositWithdrawUXModel = Just ( Withdraw, { amountInput = TokenValue.toFloatString Nothing defaultValue } )
                }

        DoExit ->
            UpdateResult
                prevModel
                Cmd.none
                doExitChainCmd
                []

        DoClaimRewards ->
            UpdateResult
                prevModel
                Cmd.none
                doClaimRewards
                []

        DoDeposit amount ->
            UpdateResult
                prevModel
                Cmd.none
                (doDepositChainCmd amount)
                []

        DoWithdraw amount ->
            UpdateResult
                prevModel
                Cmd.none
                (doWithdrawChainCmd amount)
                []

        RefetchStakingInfo ->
            UpdateResult
                prevModel
                (case Wallet.userInfo prevModel.wallet of
                    Just userInfo ->
                        fetchUserStakingInfoCmd userInfo.address

                    Nothing ->
                        Cmd.none
                )
                ChainCmd.none
                []

        StakingInfoFetched fetchResult ->
            case fetchResult of
                Err httpErr ->
                    UpdateResult
                        prevModel
                        Cmd.none
                        ChainCmd.none
                        [ Common.Msg.AddUserNotice <| UN.web3FetchError "staking info" httpErr ]

                Ok userStakingInfo ->
                    justModelUpdate
                        { prevModel
                            | userStakingInfo =
                                Just userStakingInfo
                        }



-- FakeFetchBalanceInfo ->
--     justModelUpdate
--         { prevModel
--             | userStakingInfo =
--                 Just <|
--                     { unstaked = TokenValue.fromIntTokenValue 10
--                     , staked = TokenValue.fromIntTokenValue 10
--                     , claimableRewards = TokenValue.zero
--                     , rewardRate = TokenValue.fromIntTokenValue 1
--                     , timestamp = prevModel.now
--                     }
--         }


runMsgDown : MsgDown -> Model -> UpdateResult
runMsgDown msg prevModel =
    case msg of
        Common.Msg.UpdateWallet newWallet ->
            let
                newModel =
                    { prevModel
                        | wallet = newWallet
                        , userStakingInfo = Nothing
                    }

                cmd =
                    case Wallet.userInfo newWallet of
                        Just userInfo ->
                            fetchUserStakingInfoCmd userInfo.address

                        Nothing ->
                            Cmd.none
            in
            UpdateResult
                newModel
                cmd
                ChainCmd.none
                []


fetchUserStakingInfoCmd : Address -> Cmd Msg
fetchUserStakingInfoCmd userAddress =
    StakingContract.getUserStakingInfo
        userAddress
        StakingInfoFetched


doApproveChainCmd : ChainCmd Msg
doApproveChainCmd =
    ChainCmd.custom
        { onMined = Just <| (always RefetchStakingInfo, Nothing)
        , onSign = Nothing
        , onBroadcast = Nothing
        }
        StakingContract.approveLiquidityToken


doDepositChainCmd : TokenValue -> ChainCmd Msg
doDepositChainCmd amount =
    ChainCmd.custom
        { onMined = Just <| (always RefetchStakingInfo, Nothing)
        , onSign = Nothing
        , onBroadcast = Nothing
        }
        (StakingContract.stake amount)


doWithdrawChainCmd : TokenValue -> ChainCmd Msg
doWithdrawChainCmd amount =
    ChainCmd.custom
        { onMined = Just <| (always RefetchStakingInfo, Nothing)
        , onSign = Nothing
        , onBroadcast = Nothing
        }
        (StakingContract.withdraw amount)


doExitChainCmd : ChainCmd Msg
doExitChainCmd =
    ChainCmd.custom
        { onMined = Just <| (always RefetchStakingInfo, Nothing)
        , onSign = Nothing
        , onBroadcast = Nothing
        }
        StakingContract.exit


doClaimRewards : ChainCmd Msg
doClaimRewards =
    ChainCmd.custom
        { onMined = Just <| (always RefetchStakingInfo, Nothing)
        , onSign = Nothing
        , onBroadcast = Nothing
        }
        StakingContract.claimRewards



-- doDepositCmd : TokenValue -> Cmd Msg
-- doDepositCmd amount =
--     StakingContract.callStake
--         amount
--         (always NoOp)


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every 50 UpdateNow
        , Time.every 10 (always RefetchStakingInfo)
        ]
